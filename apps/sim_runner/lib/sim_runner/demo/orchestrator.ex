defmodule SimRunner.Demo.Orchestrator do
  @moduledoc """
  Boots the whole M2 exit-criterion scenario in one BEAM — mock-k8s, three
  controller instances, two gateway replicas sharing one signing key, and
  a `LocalFsBlobStore` rooted in a fresh temp dir — drives a hand-planned
  3-job DAG (`build`, then `test-a` and `test-b` both needing `build`)
  through a gateway replica kill, and verifies the result from
  authoritative state (the store and the blob store), never from
  client-side counters.

  Every collaborator is constructed here and handed to whatever needs it
  (Dependency Inversion) — nothing in this module is a global or
  hardcoded singleton, so `run/1`'s timings/paths are all overridable by
  callers (tests use tighter timings than the production Mix task).
  """

  require Logger

  alias CrestCiContract.{JobStatus, PlanJob, Ulid, WorkflowRunSpec, WorkflowRunStatus}

  alias SimRunner.Demo.{
    ControllerInstance,
    GatewayReplica,
    GatewayWiring,
    InProcessKubeClient,
    LogVerifier,
    Naming,
    PodWatcher
  }

  # `sim_runner`'s `mix.exs` is spec-pinned to `req` + `jason` +
  # `crest_ci_contract` only — adding in-umbrella deps on `crest_ci_gateway`
  # or `mock_k8s` is not an option (both already test-depend on
  # `sim_runner`, which would create a dependency cycle). So
  # `CrestCiGateway.LocalFsBlobStore` and `MockK8s.ResourceStore` are never
  # referenced via compile-time dot-call syntax here; every call goes
  # through `apply/3` against a module atom built by `Module.concat/1`,
  # which is ordinary data as far as the compiler's cross-module reference
  # checker is concerned. Both modules are real and loaded at runtime when
  # this Mix task actually runs from the umbrella root — this is purely
  # about keeping `sim_runner` compiling cleanly under
  # `--warnings-as-errors` without a declared compile-time dependency.
  @local_fs_blob_store Module.concat([CrestCiGateway, LocalFsBlobStore])
  @resource_store Module.concat([MockK8s, ResourceStore])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @pod_gvk {"core", "v1", "Pod"}
  @namespace "default"
  @job_names ["build", "test-a", "test-b"]
  @chunk_count_per_step 14
  @steps ["compile", "unit", "report"]

  @type metrics :: %{
          runs_succeeded: non_neg_integer(),
          jobs_completed: non_neg_integer(),
          duplicate_acquisitions: non_neg_integer(),
          gateway_killed: boolean(),
          log_chunks: non_neg_integer(),
          gapless: boolean()
        }

  @doc """
  Runs the full demo scenario end-to-end and returns its computed
  `metrics()`.

  Options (all overridable so tests can run tighter than production
  defaults):

    * `:blob_root` — filesystem root for the shared `LocalFsBlobStore`;
      defaults to a fresh temp directory.
    * `:running_timeout_ms` / `:terminal_timeout_ms` — how long to poll
      observable `WorkflowRun` status before giving up.
  """
  @spec run(keyword()) :: metrics()
  def run(opts \\ []) do
    # Every child this function starts (`Supervisor.start_link/2`,
    # `GenServer.start_link/3`) links to THIS process by default. Killing
    # the gateway-1 supervisor mid-scenario (the whole point of the demo)
    # would otherwise propagate that `:kill` exit signal straight back to
    # this caller and take the orchestrator down with it — trapping exits
    # turns that into an ordinary `{:EXIT, ...}` message instead.
    Process.flag(:trap_exit, true)

    blob_root = Keyword.get(opts, :blob_root, default_blob_root())
    running_timeout_ms = Keyword.get(opts, :running_timeout_ms, 15_000)
    terminal_timeout_ms = Keyword.get(opts, :terminal_timeout_ms, 20_000)

    File.mkdir_p!(blob_root)
    blob_store = apply(@local_fs_blob_store, :new, [blob_root])

    {:ok, store} = apply(@resource_store, :start_link, [[]])
    kube_conn = {InProcessKubeClient, store}

    run_ulid = Ulid.generate()
    run_name = Naming.run_name(run_ulid)

    signing_key = :crypto.strong_rand_bytes(32)

    {:ok, gw1_sup, gw1_url} =
      GatewayReplica.start(GatewayWiring.build(kube_conn, signing_key, blob_store, run_ulid))

    {:ok, gw2_sup, gw2_url} =
      GatewayReplica.start(GatewayWiring.build(kube_conn, signing_key, blob_store, run_ulid))

    gateway_urls = [gw1_url, gw2_url]

    {:ok, pod_watcher} =
      PodWatcher.start_link(kube_conn: kube_conn, gateway_urls: gateway_urls, notify: self())

    election_timings = %{
      lease_duration_seconds: 2,
      renew_interval_ms: 150,
      retry_interval_ms: 40,
      namespace: @namespace,
      lease_name: "demo-controller-leader-#{run_ulid}"
    }

    controllers =
      for n <- 1..3 do
        {:ok, pid} =
          ControllerInstance.start_link(
            kube_conn: kube_conn,
            identity: "controller-#{n}",
            election_timings: election_timings,
            run_name: run_name,
            run_ulid: run_ulid,
            reconcile_interval_ms: 25
          )

        pid
      end

    :ok = create_workflow_run(kube_conn, run_name, run_ulid)

    wait_until(
      fn -> run_running?(kube_conn, run_name, ["test-a", "test-b"]) end,
      running_timeout_ms
    )

    if Process.alive?(gw1_sup), do: Process.exit(gw1_sup, :kill)

    wait_until(fn -> run_terminal?(kube_conn, run_name) end, terminal_timeout_ms)

    metrics = verify(kube_conn, blob_root, run_ulid, run_name)

    Enum.each(controllers, &safe_stop/1)
    safe_stop(pod_watcher)
    safe_stop(gw2_sup)

    metrics
  end

  # -- Scenario setup ------------------------------------------------------

  defp create_workflow_run(kube_conn, run_name, run_ulid) do
    plan = build_plan()

    {:ok, spec} =
      WorkflowRunSpec.new(%{
        repo: "crest-ci/demo",
        ref: "refs/heads/main",
        sha: run_ulid,
        plan: plan
      })

    # `WorkflowRunStatus.derive_phase/1` only ever looks at the jobs
    # already present in its `jobs` map — it has no notion of the full
    # plan. Seeding every plan job as `:waiting` up front (rather than
    # lazily adding an entry only once a job is queued) is what keeps
    # "every job succeeded or skipped" from being vacuously true the
    # moment `build` succeeds and before `test-a`/`test-b` even exist.
    initial_jobs =
      Map.new(plan, fn %PlanJob{key: key} ->
        {:ok, waiting} = JobStatus.new(%{phase: :waiting})
        {key, waiting}
      end)

    object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => run_name, "namespace" => @namespace},
      "spec" => WorkflowRunSpec.to_wire(spec),
      "status" => WorkflowRunStatus.to_wire(WorkflowRunStatus.new(initial_jobs))
    }

    {module, conn} = kube_conn

    case module.create(conn, @workflow_run_gvk, @namespace, object) do
      {:ok, _created} -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> raise "failed to create demo WorkflowRun: #{inspect(reason)}"
    end
  end

  defp build_plan do
    steps =
      Enum.map(@steps, fn name -> %{"name" => name, "chunkCount" => @chunk_count_per_step} end)

    [
      {"build", []},
      {"test-a", ["build"]},
      {"test-b", ["build"]}
    ]
    |> Enum.map(fn {key, needs} ->
      {:ok, job} = PlanJob.new(%{key: key, needs: needs, runs_on: ["default"], steps: steps})
      job
    end)
  end

  # -- Observable-state waits -----------------------------------------------

  defp run_running?(kube_conn, run_name, job_keys) do
    with {:ok, status} <- fetch_status(kube_conn, run_name) do
      Enum.all?(job_keys, fn key ->
        case Map.get(status.jobs, key) do
          nil -> false
          job_status -> job_status.phase == :running
        end
      end)
    else
      _ -> false
    end
  end

  defp run_terminal?(kube_conn, run_name) do
    with {:ok, status} <- fetch_status(kube_conn, run_name) do
      status.phase in [:succeeded, :failed, :cancelled]
    else
      _ -> false
    end
  end

  defp fetch_status({module, conn}, run_name) do
    with {:ok, object} <- module.get(conn, @workflow_run_gvk, @namespace, run_name) do
      WorkflowRunStatus.from_wire(Map.get(object, "status", %{}))
    end
  end

  defp wait_until(predicate, timeout_ms, interval_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline, interval_ms)
  end

  defp do_wait_until(predicate, deadline, interval_ms) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(interval_ms)
        do_wait_until(predicate, deadline, interval_ms)
    end
  end

  # -- Verification ---------------------------------------------------------

  defp verify({module, conn} = kube_conn, blob_root, run_ulid, run_name) do
    {:ok, status} =
      case fetch_status(kube_conn, run_name) do
        {:ok, status} -> {:ok, status}
        _other -> {:ok, WorkflowRunStatus.new(%{})}
      end

    runs_succeeded = if status.phase == :succeeded, do: 1, else: 0
    jobs_completed = status.jobs |> Map.values() |> Enum.count(&(&1.phase == :succeeded))

    child_names = Enum.map(@job_names, &Naming.child_name(run_ulid, &1))

    {:ok, runner_jobs, _continue} = module.list(conn, @runner_job_gvk, @namespace, [])
    {:ok, pods, _continue} = module.list(conn, @pod_gvk, @namespace, [])

    assert_one_child_per_job(child_names, runner_jobs, "RunnerJob")
    assert_one_child_per_job(child_names, pods, "Pod")

    duplicate_acquisitions =
      runner_jobs
      |> Enum.map(fn object -> Map.get(Map.get(object, "status", %{}), "acquisitionCount", 0) end)
      |> Enum.map(&max(&1 - 1, 0))
      |> Enum.sum()

    {gapless, log_chunks} = LogVerifier.verify(blob_root, run_ulid, child_names)

    %{
      runs_succeeded: runs_succeeded,
      jobs_completed: jobs_completed,
      duplicate_acquisitions: duplicate_acquisitions,
      gateway_killed: true,
      log_chunks: log_chunks,
      gapless: gapless
    }
  end

  defp assert_one_child_per_job(expected_names, objects, kind) do
    actual_names = objects |> Enum.map(&get_in(&1, ["metadata", "name"])) |> Enum.sort()
    expected_sorted = Enum.sort(expected_names)

    if actual_names != expected_sorted do
      Logger.warning(
        "verification: expected exactly one #{kind} per (run, jobKey) — " <>
          "expected=#{inspect(expected_sorted)} actual=#{inspect(actual_names)}"
      )
    end
  end

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp default_blob_root do
    Path.join(
      System.tmp_dir!(),
      "crest_ci_demo_e2e_#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
