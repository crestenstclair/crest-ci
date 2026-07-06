defmodule SimRunner.Demo.EngineOrchestrator do
  @moduledoc """
  Boots the whole M4 engine-exit-criterion scenario in one BEAM — mock-k8s,
  one `SimRunner.Demo.ControllerInstance`, and one gateway replica, all
  inside this one BEAM — and submits a single `WorkflowRun` whose `spec`
  carries a real GitHub Actions `workflowYaml` document and NO hand-built
  `plan`: the engine (`domainService.Engine.WorkflowParser` ->
  `.GithubContext` -> `.Planner`), not this harness, is what turns that
  YAML into the job DAG that gets executed.

  The workflow fixture is a realistic 4-planned-job graph: `lint` and
  `build` run with no dependencies (in parallel); `test` needs `build`
  and carries a job-level `if: ${{ github.ref == 'refs/heads/main' }}`
  that evaluates TRUE for the submitted event; `package` needs
  `[lint, test]`. A fifth job, `deploy`, needs `[package]` and carries
  `if: ${{ github.ref == 'refs/heads/release' }}` — FALSE for the
  submitted event (`ref: "refs/heads/main"`), so it must never appear in
  the planned DAG at all (excluded by exclusion, not skipped-and-present).

  Every metric this module reports is computed from measured,
  authoritative state, never a client-side guess:

    * `planned_jobs` / `excluded_by_if` come from parsing the SAME
      `workflowYaml` and running the SAME `Planner.plan/2` this harness's
      `ControllerInstance` runs server-side (see
      `SimRunner.Demo.ControllerInstance.effective_plan/1`) — the
      difference between the workflow's total declared job count and the
      planner's returned job count IS the exclude-by-if count, measured,
      not asserted;
    * the exact `needs` edges of that same locally-computed plan are
      asserted against the fixture's known structure before anything is
      submitted;
    * `runs_succeeded` is read back from the submitted `WorkflowRun`'s own
      authoritative `status.phase` after driving it to completion with
      real `SimRunner.RunnerClient`s;
    * `plan_deterministic` calls `Planner.plan/2` a second time against
      byte-identical `(definition, github_context)` inputs and compares
      the two plans' `Jason`-encoded wire bytes — this is what "the same
      YAML+event in-process yields a byte-identical plan" means measured,
      not assumed.

  Every collaborator is constructed here and handed to whatever needs it
  (Dependency Inversion) — nothing in this module is a global or
  hardcoded singleton, so `run/1`'s timings/paths are all overridable by
  callers (tests use tighter timings than the production Mix task).
  """

  alias CrestCiContract.{PlanJob, Ulid, WorkflowRunSpec, WorkflowRunStatus}

  alias SimRunner.Demo.{
    ControllerInstance,
    GatewayReplica,
    GatewayWiring,
    InProcessKubeClient,
    Naming,
    PodWatcher
  }

  # Same `Module.concat/1` + `apply/3` dodge as `ControllerInstance` and
  # `Orchestrator` use for their own out-of-declared-deps collaborators —
  # see either moduledoc for why: `sim_runner`'s own `mix.exs` cannot carry
  # a compile-time in-umbrella dep on `crest_ci_controller` (which already
  # test-depends on `sim_runner`) without creating a dependency cycle.
  @workflow_parser Module.concat([CrestCiController, Engine, WorkflowParser])
  @github_context Module.concat([CrestCiController, Engine, GithubContext])
  @planner Module.concat([CrestCiController, Engine, Planner])
  @resource_store Module.concat([MockK8s, ResourceStore])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  @expected_needs %{
    "lint" => [],
    "build" => [],
    "test" => ["build"],
    "package" => ["lint", "test"]
  }
  @expected_job_keys Map.keys(@expected_needs) |> Enum.sort()
  @excluded_job_key "deploy"

  @workflow_yaml """
  name: demo-engine
  on:
    push:
      branches: [main]
  env:
    GLOBAL_FLAG: "on"
  jobs:
    lint:
      runs-on: [default]
      steps:
        - run: echo lint
    build:
      runs-on: [default]
      steps:
        - run: echo build
    test:
      needs: [build]
      if: ${{ github.ref == 'refs/heads/main' }}
      runs-on: [default]
      steps:
        - run: echo test
    package:
      needs: [lint, test]
      runs-on: [default]
      steps:
        - run: echo package
    deploy:
      needs: [package]
      if: ${{ github.ref == 'refs/heads/release' }}
      runs-on: [default]
      steps:
        - run: echo deploy
  """

  @submitted_repo "crest-ci/demo-engine"
  @submitted_ref "refs/heads/main"

  @type metrics :: %{
          planned_jobs: non_neg_integer(),
          excluded_by_if: non_neg_integer(),
          runs_succeeded: non_neg_integer(),
          plan_deterministic: boolean()
        }

  @doc """
  Runs the full engine-planned scenario end-to-end and returns its
  computed `metrics()`.

  Options (all overridable so tests can run tighter than production
  defaults):

    * `:running_timeout_ms` / `:terminal_timeout_ms` — how long to poll
      observable `WorkflowRun` status before giving up.
  """
  @spec run(keyword()) :: metrics()
  def run(opts \\ []) do
    Process.flag(:trap_exit, true)

    running_timeout_ms = Keyword.get(opts, :running_timeout_ms, 15_000)
    terminal_timeout_ms = Keyword.get(opts, :terminal_timeout_ms, 20_000)

    run_sha = Ulid.generate()

    # -- Independent, in-process planning (never touches the store) -------
    #
    # This is the "re-planning the same YAML+event in-process yields a
    # byte-identical plan" measurement, AND the source of the
    # `planned_jobs` / `excluded_by_if` / exact-needs-edges assertions —
    # computed with the SAME pure engine pipeline the server-side harness
    # (`ControllerInstance.effective_plan/1`) runs, so "matches the YAML's
    # structure" is a real cross-check, not a tautology against a
    # hand-copied expectation.
    {definition, github_ctx} = parse_and_context!(run_sha)
    plan_a = plan!(definition, github_ctx)
    plan_b = plan!(definition, github_ctx)

    plan_deterministic = encode_plan(plan_a) == encode_plan(plan_b)
    assert_matches_yaml_structure!(definition, plan_a)

    planned_jobs = length(plan_a)
    excluded_by_if = map_size(definition.jobs) - planned_jobs

    # -- Boot the in-BEAM stack and drive the SAME workflowYaml through it -
    {:ok, store} = apply(@resource_store, :start_link, [[]])
    kube_conn = {InProcessKubeClient, store}

    run_ulid = Ulid.generate()
    run_name = Naming.run_name(run_ulid)

    signing_key = :crypto.strong_rand_bytes(32)
    blob_root = default_blob_root()
    File.mkdir_p!(blob_root)
    blob_store = apply(Module.concat([CrestCiGateway, LocalFsBlobStore]), :new, [blob_root])

    {:ok, gw_sup, gw_url} =
      GatewayReplica.start(GatewayWiring.build(kube_conn, signing_key, blob_store, run_ulid))

    gateway_urls = [gw_url]

    {:ok, pod_watcher} =
      PodWatcher.start_link(kube_conn: kube_conn, gateway_urls: gateway_urls, notify: self())

    election_timings = %{
      lease_duration_seconds: 2,
      renew_interval_ms: 150,
      retry_interval_ms: 40,
      namespace: @namespace,
      lease_name: "demo-engine-controller-leader-#{run_ulid}"
    }

    {:ok, controller} =
      ControllerInstance.start_link(
        kube_conn: kube_conn,
        identity: "controller-engine-1",
        election_timings: election_timings,
        run_name: run_name,
        run_ulid: run_ulid,
        reconcile_interval_ms: 25
      )

    :ok = create_workflow_run(kube_conn, run_name, run_sha)

    wait_until(
      fn -> run_reached_expected_jobs?(kube_conn, run_name) end,
      running_timeout_ms
    )

    wait_until(fn -> run_terminal?(kube_conn, run_name) end, terminal_timeout_ms)

    runs_succeeded = verify_run(kube_conn, run_name)

    safe_stop(controller)
    safe_stop(pod_watcher)
    safe_stop(gw_sup)

    %{
      planned_jobs: planned_jobs,
      excluded_by_if: excluded_by_if,
      runs_succeeded: runs_succeeded,
      plan_deterministic: plan_deterministic
    }
  end

  # -- Independent planning ------------------------------------------------

  defp parse_and_context!(run_sha) do
    {:ok, definition, _warnings} = apply(@workflow_parser, :parse, [@workflow_yaml])

    {:ok, github_context} =
      apply(@github_context, :new, [
        %{
          actor: "",
          event: %{},
          event_name: "push",
          ref: @submitted_ref,
          repository: @submitted_repo,
          sha: run_sha
        }
      ])

    {definition, github_context}
  end

  defp plan!(definition, github_context) do
    case apply(@planner, :plan, [definition, github_context]) do
      {:ok, plan} -> plan
      {:error, reason} -> raise "engine failed to plan demo workflow: #{inspect(reason)}"
    end
  end

  defp encode_plan(plan) do
    plan |> Enum.map(&PlanJob.to_wire/1) |> Jason.encode!()
  end

  defp assert_matches_yaml_structure!(definition, plan) do
    actual_keys = plan |> Enum.map(& &1.key) |> Enum.sort()

    if actual_keys != @expected_job_keys do
      raise "planned job keys #{inspect(actual_keys)} do not match expected #{inspect(@expected_job_keys)}"
    end

    if Map.has_key?(definition.jobs, @excluded_job_key) and
         @excluded_job_key in actual_keys do
      raise "expected #{@excluded_job_key} to be excluded by its false if, but it was planned"
    end

    actual_needs =
      Map.new(plan, fn %PlanJob{key: key, needs: needs} -> {key, Enum.sort(needs)} end)

    expected_needs = Map.new(@expected_needs, fn {key, needs} -> {key, Enum.sort(needs)} end)

    if actual_needs != expected_needs do
      raise "planned needs edges #{inspect(actual_needs)} do not match expected #{inspect(expected_needs)}"
    end
  end

  # -- Scenario setup -------------------------------------------------------

  defp create_workflow_run(kube_conn, run_name, run_sha) do
    {:ok, spec} =
      WorkflowRunSpec.new(%{
        repo: @submitted_repo,
        ref: @submitted_ref,
        sha: run_sha,
        plan: []
      })

    spec_wire = spec |> WorkflowRunSpec.to_wire() |> Map.put("workflowYaml", @workflow_yaml)

    object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => run_name, "namespace" => @namespace},
      "spec" => spec_wire,
      "status" => WorkflowRunStatus.to_wire(WorkflowRunStatus.new(%{}))
    }

    {module, conn} = kube_conn

    case module.create(conn, @workflow_run_gvk, @namespace, object) do
      {:ok, _created} -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> raise "failed to create demo WorkflowRun: #{inspect(reason)}"
    end
  end

  # -- Observable-state waits -----------------------------------------------

  defp run_reached_expected_jobs?(kube_conn, run_name) do
    with {:ok, status} <- fetch_status(kube_conn, run_name) do
      job_keys = status.jobs |> Map.keys() |> Enum.sort()
      job_keys == @expected_job_keys
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

  defp verify_run(kube_conn, run_name) do
    case fetch_status(kube_conn, run_name) do
      {:ok, %WorkflowRunStatus{phase: :succeeded} = status} ->
        never_ran_excluded_job!(status)
        all_planned_jobs_succeeded!(status)
        1

      _other ->
        0
    end
  end

  defp never_ran_excluded_job!(%WorkflowRunStatus{jobs: jobs}) do
    if Map.has_key?(jobs, @excluded_job_key) do
      raise "#{@excluded_job_key} (false job-level if) must never appear in job status, got: #{inspect(Map.get(jobs, @excluded_job_key))}"
    end
  end

  defp all_planned_jobs_succeeded!(%WorkflowRunStatus{jobs: jobs}) do
    Enum.each(@expected_job_keys, fn key ->
      case Map.get(jobs, key) do
        %{phase: :succeeded} ->
          :ok

        other ->
          raise "expected job #{key} to have succeeded, got: #{inspect(other)}"
      end
    end)
  end

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp default_blob_root do
    Path.join(
      System.tmp_dir!(),
      "crest_ci_demo_engine_#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
