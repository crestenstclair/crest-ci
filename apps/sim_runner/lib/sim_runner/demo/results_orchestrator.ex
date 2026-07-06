defmodule SimRunner.Demo.ResultsOrchestrator do
  @moduledoc """
  Boots the whole results-verification scenario for
  `mix crest_ci.demo_results`: TWO sequential `WorkflowRun`s, each
  through its own fresh in-BEAM boot (mock-k8s, three controller
  instances, two gateway replicas sharing one signing key, and a
  `LocalFsBlobStore` rooted in a shared temp dir) — every collaborator
  is constructed here and handed to whatever needs it (Dependency
  Inversion), exactly like `SimRunner.Demo.Orchestrator`.

  Each run's single job (`"build"`) carries steps of kind
  `checkout`, `cache_restore`, `upload_artifact`, and `cache_save`. The
  real runner protocol (`SimRunner.RunnerClient` via
  `SimRunner.Demo.PodWatcher`) drives every step's log chunks to
  completion exactly as `SimRunner.Demo.Orchestrator` does — that is
  what makes "every job's archive is gapless" a real,
  authoritative-state check (reusing `SimRunner.Demo.LogVerifier`,
  exactly the same compaction-verification approach the 3-job DAG demo
  uses).

  Artifact upload/download and cache restore/save are not wired through
  the runner HTTP protocol anywhere in this project — no step kind is
  interpreted by `SimRunner.RunnerClient` today — so this orchestrator
  performs those two actions itself, once per run, against
  `SimRunner.Demo.LocalArtifactStore` and
  `SimRunner.Demo.LocalCacheStore` — both real, filesystem-backed
  adapters owned by this demo, never ETS/Agent state. The cache root is
  shared across both runs (each run's controller/gateway boot is
  otherwise fully independent and torn down before the next run
  starts), which is what makes "cache miss on run 1, cache hit on run
  2" an on-disk fact rather than an in-process one.
  """

  alias CrestCiContract.{JobStatus, PlanJob, Ulid, WorkflowRunSpec, WorkflowRunStatus}

  alias SimRunner.Demo.{
    ControllerInstance,
    GatewayReplica,
    GatewayWiring,
    InProcessKubeClient,
    LocalArtifactStore,
    LocalCacheStore,
    LogVerifier,
    Naming,
    PodWatcher
  }

  # `sim_runner`'s `mix.exs` is spec-pinned to `req` + `jason` +
  # `crest_ci_contract` only — adding in-umbrella deps on
  # `crest_ci_gateway` or `mock_k8s` is not an option (both already
  # test-depend on `sim_runner`, which would create a dependency
  # cycle). So `CrestCiGateway.LocalFsBlobStore` and
  # `MockK8s.ResourceStore` are never referenced via compile-time
  # dot-call syntax here; every call goes through `apply/3` against a
  # module atom built by `Module.concat/1`, which is ordinary data as
  # far as the compiler's cross-module reference checker is concerned.
  # Both modules are real and loaded at runtime when this Mix task
  # actually runs from the umbrella root — this is purely about keeping
  # `sim_runner` compiling cleanly under `--warnings-as-errors` without
  # a declared compile-time dependency. (Same convention as
  # `SimRunner.Demo.Orchestrator`.)
  @local_fs_blob_store Module.concat([CrestCiGateway, LocalFsBlobStore])
  @resource_store Module.concat([MockK8s, ResourceStore])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"
  @job_key "build"
  @artifact_name "build-output.bin"
  @cache_key "demo-cache-key-v1"
  @artifact_size_bytes 65_536

  @type run_result :: %{
          succeeded: boolean(),
          artifact_verified: boolean(),
          cache_hit: boolean(),
          gapless: boolean()
        }

  @type metrics :: %{
          runs_succeeded: non_neg_integer(),
          artifacts_verified: non_neg_integer(),
          cache_hit_second_run: boolean(),
          archive_gaps: non_neg_integer()
        }

  @doc """
  Runs the full two-run demo scenario end-to-end and returns its
  computed `metrics()`.

  Options (all overridable so tests can run tighter than production
  defaults):

    * `:blob_root` — filesystem root for each run's `LocalFsBlobStore`
      and this demo's `LocalArtifactStore`; defaults to a fresh temp
      directory.
    * `:cache_root` — filesystem root for `LocalCacheStore`, shared
      across BOTH runs; defaults to a fresh temp directory.
    * `:terminal_timeout_ms` — how long to poll observable `WorkflowRun`
      status per run before giving up.
  """
  @spec run(keyword()) :: metrics()
  def run(opts \\ []) do
    blob_root = Keyword.get(opts, :blob_root, default_root("blob"))
    cache_root = Keyword.get(opts, :cache_root, default_root("cache"))
    terminal_timeout_ms = Keyword.get(opts, :terminal_timeout_ms, 20_000)

    File.mkdir_p!(blob_root)
    File.mkdir_p!(cache_root)

    run_results =
      for _run_index <- 1..2 do
        run_one(blob_root, cache_root, terminal_timeout_ms)
      end

    aggregate(run_results)
  end

  # -- One full run: fresh boot, one job, artifact + cache actions --------

  @spec run_one(String.t(), String.t(), non_neg_integer()) :: run_result()
  defp run_one(blob_root, cache_root, terminal_timeout_ms) do
    # Every child this function starts links to THIS process by default;
    # trapping exits keeps a killed/crashed child's exit signal from
    # propagating back and taking the whole demo down (same discipline
    # as `SimRunner.Demo.Orchestrator`, even though this scenario never
    # deliberately kills a replica).
    Process.flag(:trap_exit, true)

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

    # `cache_restore` happens before the job runs, mirroring what a real
    # runner's cache_restore step would observe at that point: run 1
    # sees nothing saved yet (a soft miss); run 2 sees run 1's committed
    # save (a hit) — read from the SAME on-disk cache root passed in by
    # `run/1`, since each run's controller/gateway boot is otherwise
    # fully independent.
    cache_hit? = match?({:ok, _content}, LocalCacheStore.restore(cache_root, @cache_key))

    :ok = create_workflow_run(kube_conn, run_name, run_ulid)

    wait_until(fn -> run_terminal?(kube_conn, run_name) end, terminal_timeout_ms)

    succeeded? = run_succeeded?(kube_conn, run_name)

    artifact_verified? = upload_and_verify_artifact(blob_root, run_ulid)

    :ok = LocalCacheStore.save(cache_root, @cache_key, cache_content())

    # `LogVerifier`/the blob store key log chunks by the RunnerJob's own
    # deterministic child NAME (`Naming.child_name/2`), never by the bare
    # plan job KEY — the runner's job message's `jobName` is the child
    # name, and that is what flows into `GatewayWiring`'s `ingest_chunk`.
    child_name = Naming.child_name(run_ulid, @job_key)
    {gapless?, _chunks} = LogVerifier.verify(blob_root, run_ulid, [child_name])

    Enum.each(controllers, &safe_stop/1)
    safe_stop(pod_watcher)
    safe_stop(gw1_sup)
    safe_stop(gw2_sup)
    safe_stop(store)

    %{
      succeeded: succeeded?,
      artifact_verified: artifact_verified?,
      cache_hit: cache_hit?,
      gapless: gapless?
    }
  end

  # -- Scenario setup ------------------------------------------------------

  defp create_workflow_run(kube_conn, run_name, run_ulid) do
    {:ok, job} =
      PlanJob.new(%{
        key: @job_key,
        needs: [],
        runs_on: ["default"],
        steps: job_steps()
      })

    {:ok, spec} =
      WorkflowRunSpec.new(%{
        repo: "crest-ci/results-demo",
        ref: "refs/heads/main",
        sha: run_ulid,
        plan: [job]
      })

    {:ok, waiting} = JobStatus.new(%{phase: :waiting})
    initial_jobs = %{@job_key => waiting}

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

  defp job_steps do
    [
      %{"name" => "checkout", "chunkCount" => 4, "kind" => "checkout"},
      %{"name" => "cache_restore", "chunkCount" => 3, "kind" => "cache_restore"},
      %{"name" => "upload_artifact", "chunkCount" => 4, "kind" => "upload_artifact"},
      %{"name" => "cache_save", "chunkCount" => 3, "kind" => "cache_save"}
    ]
  end

  # -- Artifact upload/verify -----------------------------------------------

  # Uploads a deterministic ~64KiB payload for this run and immediately
  # reads it back, comparing digests — never trusting a client-side
  # counter or the write call's own return value as proof of a correct
  # round-trip.
  defp upload_and_verify_artifact(blob_root, run_ulid) do
    payload = artifact_payload()
    uploaded_digest = LocalArtifactStore.digest(payload)

    :ok = LocalArtifactStore.put(blob_root, run_ulid, @artifact_name, payload)

    case LocalArtifactStore.get(blob_root, run_ulid, @artifact_name) do
      {:ok, downloaded} -> LocalArtifactStore.digest(downloaded) == uploaded_digest
      {:error, _reason} -> false
    end
  end

  # A fixed, non-random ~64KiB (65,536 byte) payload: 256 repetitions of
  # the 256-byte sequence `<<0, 1, 2, ..., 255>>`. Deterministic and
  # reproducible run over run — no randomness that could make a digest
  # mismatch ambiguous between "storage bug" and "different content".
  defp artifact_payload do
    pattern = for byte <- 0..255, into: <<>>, do: <<byte>>
    String.duplicate(pattern, div(@artifact_size_bytes, byte_size(pattern)))
  end

  defp cache_content, do: "demo-results-cache-blob-v1"

  # -- Observable-state waits -----------------------------------------------

  defp run_terminal?(kube_conn, run_name) do
    with {:ok, status} <- fetch_status(kube_conn, run_name) do
      status.phase in [:succeeded, :failed, :cancelled]
    else
      _other -> false
    end
  end

  defp run_succeeded?(kube_conn, run_name) do
    case fetch_status(kube_conn, run_name) do
      {:ok, status} -> status.phase == :succeeded
      _other -> false
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

  # -- Aggregation -----------------------------------------------------------

  @spec aggregate([run_result()]) :: metrics()
  defp aggregate(run_results) do
    runs_succeeded = Enum.count(run_results, & &1.succeeded)
    artifacts_verified = Enum.count(run_results, & &1.artifact_verified)
    archive_gaps = Enum.count(run_results, &(not &1.gapless))

    cache_hit_second_run =
      case Enum.at(run_results, 1) do
        %{cache_hit: hit?} -> hit?
        nil -> false
      end

    %{
      runs_succeeded: runs_succeeded,
      artifacts_verified: artifacts_verified,
      cache_hit_second_run: cache_hit_second_run,
      archive_gaps: archive_gaps
    }
  end

  # -- Helpers ---------------------------------------------------------------

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp default_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "crest_ci_demo_results_#{suffix}_#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
