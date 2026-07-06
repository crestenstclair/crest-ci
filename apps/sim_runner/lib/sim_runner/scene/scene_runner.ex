defmodule SimRunner.Scene.SceneRunner do
  @moduledoc """
  `applicationService.Scene.SceneRunner` — the scene's conductor.

  Boots the whole in-BEAM stack (mock-k8s, N controller instances behind a
  shared coordination Lease, M gateway replicas, and a content-addressed
  blob store rooted in a fresh temp dir — the same collaborators
  `SimRunner.Demo.Orchestrator` / `SimRunner.Demo.EngineOrchestrator` boot,
  reused the same way), starts a `SimRunner.Scene.ScenarioDirector` (the
  steady workload trickle) and a `SimRunner.Scene.ChaosDirector` (the
  scripted timeline), ticks a snapshot -> render loop
  (`SimRunner.Scene.StateSnapshotter.take/3` ->
  `SimRunner.Scene.TtyRenderer.render/5`) at ~4 frames/s in `:tty` mode or
  ~1/s headless, stops at `duration_s` (or runs until `stop_check` reports
  true when `forever?` is set), runs a post-stop verification pass, prints
  a human-readable summary table, and returns the measured
  `SimRunner.Scene.Scoreboard`.

  `run/1` is the conductor `mix crest_ci.demo_scene` calls: that task is
  the thin CLI edge that turns environment variables into this function's
  options map and owns the ONE machine-parseable `scoreboard ...` summary
  line and non-zero-exit decision (see its own moduledoc) — this module
  never calls `System.halt/1` or `Mix.raise/1` itself, only ever returns
  a `Scoreboard.t()`, so it stays a plain, testable function.

  ## Why this module reconciles runs itself instead of reusing
  ## `SimRunner.Demo.ControllerInstance`

  `SimRunner.Demo.ControllerInstance` (and the `SimRunner.Demo.GatewayWiring`
  it composes with) were built for the earlier, single-run demo harnesses:
  `ControllerInstance` reconciles exactly one hardcoded `run_name`, and
  `GatewayWiring.build/4`'s `run_ulid` argument — baked into its
  `project_status` callback as `Naming.run_name(run_ulid)` — assumes
  every job dispatched through that gateway belongs to that ONE run. A
  scene submits many independent `WorkflowRun`s concurrently, so this
  module runs its OWN private multi-run reconciler
  (`SimRunner.Scene.SceneRunner.MultiRunController`, below) that lists and reconciles
  EVERY non-terminal `WorkflowRun` each pass — composing the exact same
  underlying collaborators (`CrestCiController.LeaderElector`,
  `.LeaseSweeper`, `.NeedsResolver`, the Engine `WorkflowParser` ->
  `GithubContext` -> `Planner` pipeline) `ControllerInstance` does, the
  same `Module.concat/1` + `apply/3` dodge and all, just generalized from
  one run to N.

  This also means `GatewayWiring`'s job-status projection (`Deps.project_status`,
  gateway-driven `WorkflowRunStatus.jobs` phase transitions) is only ever
  correctly attributed to whichever single `run_ulid` a gateway replica was
  built with — for a multi-run scene it is not authoritative. This module
  therefore derives `runs_succeeded`/`runs_failed` for the `Scoreboard`
  directly from `RunnerJob` status (unaffected by that closure — every
  `RunnerJob` is looked up by its own globally-unique, ULID-derived name)
  cross-referenced against each run's own recomputed plan, rather than
  trusting `WorkflowRunStatus.phase` for anything but the plan-error
  `:failed` transition this module's own reconciler writes directly. Every
  other counter (`duplicate_acquisitions`, `archive_gaps` via
  `SimRunner.Demo.LogVerifier`, the chaos-derived counters) reads
  authoritative state unaffected by this limitation.

  ## Dependency inversion

  Every collaborator (`kube_conn`, blob store, gateway replicas, controller
  instances, both directors) is constructed inside `run/1` and handed to
  whatever needs it — nothing here is a hardcoded singleton, so every
  timing knob is overridable by `opts` (tests run tighter than the
  production `mix crest_ci.demo_scene` defaults).
  """

  require Logger

  alias CrestCiContract.{RunnerJobStatus, Ulid, WorkflowRunStatus}
  alias SimRunner.Demo.{GatewayReplica, GatewayWiring, InProcessKubeClient, LogVerifier, Naming}
  alias SimRunner.Scene.{ChaosDirector, ChaosTimeline, ScenarioDirector, SceneEvent, Scoreboard}
  alias SimRunner.Scene.{StateSnapshotter, TtyRenderer}

  # Same `Module.concat/1` + `apply/3` dodge every other `sim_runner` demo
  # collaborator uses: `sim_runner`'s own `mix.exs` is spec-pinned to
  # `req` + `jason` + `crest_ci_contract` only (an in-umbrella dep on
  # `mock_k8s` / `crest_ci_gateway` / `crest_ci_controller` would create a
  # cycle, since all three already test-depend on `sim_runner`). Every
  # module below is real and on the code path whenever this actually runs
  # (umbrella-wide `mix test`, or `mix crest_ci.demo_scene` from the
  # umbrella root).
  @resource_store Module.concat([MockK8s, ResourceStore])
  @local_fs_blob_store Module.concat([CrestCiGateway, LocalFsBlobStore])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"
  @default_lease_name "crest-ci-controller"

  @default_duration_s 90
  @baseline_duration_s 90
  @default_controller_count 3
  @default_gateway_count 2
  @default_scenario_interval_ms 5_000
  @default_tty_tick_interval_ms 250
  @default_headless_tick_interval_ms 1_000
  @default_election_timings %{
    lease_duration_seconds: 2,
    renew_interval_ms: 150,
    retry_interval_ms: 40
  }

  @typedoc """
  Options for `run/1`. Every key is optional; the only keys the shipped
  `mix crest_ci.demo_scene` task actually sets are `:duration_s`,
  `:forever?`, and `:headless?` — everything else exists so tests can run
  a tighter, fully-isolated scene.
  """
  @type opts :: %{optional(atom()) => term()}

  @doc """
  Runs one full scene end-to-end and returns its measured `Scoreboard`.

  Options:

    * `:duration_s` — scene duration in seconds; defaults to `90`.
    * `:forever?` — ignore `:duration_s` and run until `:stop_check`
      reports `true`; defaults to `false`.
    * `:headless?` — force plain append-only narration instead of an ANSI
      redraw; defaults to `SimRunner.Scene.TtyRenderer.detect_mode/2 ==
      :headless`.
    * `:stop_check` — zero-arity function polled once per tick; a scene
      stops as soon as it returns `true` (checked in addition to, not
      instead of, the duration cutoff). Defaults to `fn -> false end`.
      This is the seam a real interactive Ctrl-C would need to be wired
      to by whatever process traps the OS signal — this pure conductor
      does not itself install a signal handler.
    * `:controller_count` — defaults to `3`.
    * `:gateway_count` — defaults to `2`.
    * `:scenario_interval_ms` — `ScenarioDirector` trickle cadence;
      defaults to `5_000`.
    * `:chaos_timeline` — defaults to `ChaosTimeline.default/0`,
      proportionally compressed (see the moduledoc) when `:duration_s` is
      shorter than the timeline's own 90s baseline.
    * `:election_timings` — merged over
      `%{lease_duration_seconds: 2, renew_interval_ms: 150,
      retry_interval_ms: 40}`.
    * `:tick_interval_ms` — the render loop's own cadence; defaults to
      `250` (`~4x/s`) in `:tty` mode, `1_000` (`~1x/s`) headless.
    * `:blob_root` — filesystem root for the shared blob store; defaults
      to a fresh temp directory.
  """
  @spec run(opts()) :: Scoreboard.t()
  def run(opts \\ %{}) when is_map(opts) do
    Process.flag(:trap_exit, true)

    duration_s = Map.get(opts, :duration_s, @default_duration_s)
    forever? = Map.get(opts, :forever?, false)
    headless? = Map.get(opts, :headless?, TtyRenderer.detect_mode() == :headless)
    stop_check = Map.get(opts, :stop_check, fn -> false end)

    tick_interval_ms =
      Map.get(opts, :tick_interval_ms, default_tick_interval_ms(headless?))

    duration_ms = duration_s * 1000
    chaos_timeline = Map.get(opts, :chaos_timeline, scaled_default_timeline(duration_s))

    ctx = boot(opts)

    scene_state = %{
      kube_conn: ctx.kube_conn,
      lease_name: ctx.lease_name,
      duration_ms: duration_ms,
      forever?: forever?,
      headless?: headless?,
      tick_interval_ms: tick_interval_ms,
      stop_check: stop_check,
      start_ms: System.monotonic_time(:millisecond),
      all_narration: [],
      pending_narration: []
    }

    {:ok, scenario_director} =
      ScenarioDirector.start_link(
        kube_conn: ctx.kube_conn,
        gateway_urls: ctx.gateway_urls,
        interval_ms: Map.get(opts, :scenario_interval_ms, @default_scenario_interval_ms),
        notify: self()
      )

    {:ok, chaos_director} =
      ChaosDirector.start_link(
        kube_conn: ctx.kube_conn,
        timeline: chaos_timeline,
        controllers: ctx.controllers,
        gateways: ctx.gateways,
        lease_name: ctx.lease_name,
        notify: self()
      )

    final_state = run_loop(scene_state)

    scoreboard =
      verify(ctx.kube_conn, ctx.blob_root, ctx.scene_ulid, ChaosDirector.history(chaos_director))

    safe_stop(scenario_director)
    safe_stop(chaos_director)
    Enum.each(ctx.controllers, &safe_stop(&1.pid))
    Enum.each(ctx.gateways, &safe_stop(&1.pid))

    print_summary_table(scoreboard, final_state)

    scoreboard
  end

  # -- Boot ------------------------------------------------------------------

  defp boot(opts) do
    controller_count = Map.get(opts, :controller_count, @default_controller_count)
    gateway_count = Map.get(opts, :gateway_count, @default_gateway_count)
    lease_name = Map.get(opts, :lease_name, @default_lease_name)
    blob_root = Map.get(opts, :blob_root, default_blob_root())

    File.mkdir_p!(blob_root)

    scene_ulid = Ulid.generate()
    blob_store = apply(@local_fs_blob_store, :new, [blob_root])

    {:ok, store} = apply(@resource_store, :start_link, [[]])
    kube_conn = {InProcessKubeClient, store}

    signing_key = :crypto.strong_rand_bytes(32)

    gateways =
      for _n <- 1..gateway_count do
        {:ok, sup, url} =
          GatewayReplica.start(
            GatewayWiring.build(kube_conn, signing_key, blob_store, scene_ulid)
          )

        %{pid: sup, url: url}
      end

    election_timings =
      @default_election_timings
      |> Map.merge(Map.get(opts, :election_timings, %{}))
      |> Map.put(:namespace, @namespace)
      |> Map.put(:lease_name, lease_name)

    controllers =
      for n <- 1..controller_count do
        identity = "scene-controller-#{n}"

        {:ok, pid} =
          SimRunner.Scene.SceneRunner.MultiRunController.start_link(
            kube_conn: kube_conn,
            identity: identity,
            election_timings: election_timings,
            reconcile_interval_ms: 25
          )

        %{identity: identity, pid: pid}
      end

    %{
      kube_conn: kube_conn,
      blob_root: blob_root,
      scene_ulid: scene_ulid,
      lease_name: lease_name,
      gateways: gateways,
      gateway_urls: Enum.map(gateways, & &1.url),
      controllers: controllers
    }
  end

  @spec default_tick_interval_ms(boolean()) :: pos_integer()
  defp default_tick_interval_ms(true), do: @default_headless_tick_interval_ms
  defp default_tick_interval_ms(false), do: @default_tty_tick_interval_ms

  @spec default_blob_root() :: String.t()
  defp default_blob_root do
    Path.join(
      System.tmp_dir!(),
      "crest_ci_demo_scene_#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  @spec scaled_default_timeline(pos_integer()) :: [SceneEvent.t()]
  defp scaled_default_timeline(duration_s) when duration_s >= @baseline_duration_s do
    ChaosTimeline.default()
  end

  defp scaled_default_timeline(duration_s) do
    scale = duration_s / @baseline_duration_s

    Enum.map(ChaosTimeline.default(), fn %SceneEvent{at_ms: at_ms} = event ->
      %{event | at_ms: round(at_ms * scale)}
    end)
  end

  # -- Tick loop ---------------------------------------------------------------

  defp run_loop(state) do
    receive do
      {ChaosDirector, _pid, {:narration, line}} ->
        run_loop(%{state | pending_narration: state.pending_narration ++ [line]})

      _other ->
        run_loop(state)
    after
      state.tick_interval_ms ->
        state = tick(state)

        if stop?(state) do
          state
        else
          run_loop(state)
        end
    end
  end

  defp tick(state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_ms

    snapshot =
      case StateSnapshotter.take(state.kube_conn, elapsed_ms, lease_name: state.lease_name) do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %SimRunner.Scene.Snapshot{elapsed_ms: elapsed_ms}
      end

    all_narration = state.all_narration ++ state.pending_narration

    render_lines = if state.headless?, do: state.pending_narration, else: all_narration
    mode = if state.headless?, do: :headless, else: :tty

    case TtyRenderer.render(snapshot, render_lines, elapsed_ms, state.duration_ms, mode) do
      "" -> :ok
      frame -> IO.puts(frame)
    end

    %{state | all_narration: all_narration, pending_narration: []}
  end

  defp stop?(state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_ms

    cond do
      state.stop_check.() -> true
      state.forever? -> false
      true -> elapsed_ms >= state.duration_ms
    end
  end

  # -- Verification -----------------------------------------------------------

  defp verify(kube_conn, blob_root, scene_ulid, chaos_history) do
    {module, conn} = kube_conn
    {:ok, run_objects, _continue} = module.list(conn, @workflow_run_gvk, @namespace, [])
    {:ok, runner_job_objects, _continue} = module.list(conn, @runner_job_gvk, @namespace, [])

    runner_job_status_by_name =
      Map.new(runner_job_objects, fn object ->
        {get_in(object, ["metadata", "name"]), decode_runner_job_status(object)}
      end)

    {runs_succeeded, runs_failed} = count_run_outcomes(run_objects, runner_job_status_by_name)

    duplicate_acquisitions =
      runner_job_objects
      |> Enum.map(&acquisition_count/1)
      |> Enum.map(&max(&1 - 1, 0))
      |> Enum.sum()

    cache_hits = count_cache_hits(run_objects)

    archive_gaps =
      count_archive_gaps(blob_root, scene_ulid, run_objects, runner_job_status_by_name)

    controller_failovers = count_records(chaos_history, :kill_leader, &(&1[:gap_ms] != nil))
    controller_failover_gap_ms = first_field(chaos_history, :kill_leader, :gap_ms, 0)
    gateway_failovers = count_records(chaos_history, :kill_gateway, fn _record -> true end)
    rehomed_runners = sum_field(chaos_history, :kill_gateway, :rehomed_runners)

    fields = %{
      archive_gaps: archive_gaps,
      cache_hits: cache_hits,
      controller_failover_gap_ms: controller_failover_gap_ms,
      controller_failovers: controller_failovers,
      duplicate_acquisitions: duplicate_acquisitions,
      gateway_failovers: gateway_failovers,
      rehomed_runners: rehomed_runners,
      runs_failed: runs_failed,
      runs_succeeded: runs_succeeded
    }

    case Scoreboard.new(fields) do
      {:ok, scoreboard} ->
        scoreboard

      {:error, reason} ->
        Logger.warning("SceneRunner: invalid scoreboard fields #{inspect(reason)}, using zeros")
        %Scoreboard{}
    end
  end

  # A run already marked `:failed` (this module's own reconciler writes
  # that directly on a plan error — see `MultiRunController`) counts as
  # failed outright. Otherwise this recomputes the run's own plan (pure,
  # deterministic given the same spec) and reads EVERY planned job's
  # `RunnerJobStatus` back by its deterministic name — never
  # `WorkflowRunStatus.jobs` (see the moduledoc for why that projection
  # is not authoritative for a multi-run scene): all planned jobs
  # `Completed` with `result == "success"` is a success; any planned job
  # `Completed` with any other result is a failure; anything still
  # in-flight when the scene stopped counts as neither.
  @spec count_run_outcomes([map()], %{optional(String.t()) => RunnerJobStatus.t()}) ::
          {non_neg_integer(), non_neg_integer()}
  defp count_run_outcomes(run_objects, runner_job_status_by_name) do
    Enum.reduce(run_objects, {0, 0}, fn run_object, {succeeded, failed} ->
      case run_outcome(run_object, runner_job_status_by_name) do
        :succeeded -> {succeeded + 1, failed}
        :failed -> {succeeded, failed + 1}
        :in_progress -> {succeeded, failed}
      end
    end)
  end

  defp run_outcome(run_object, runner_job_status_by_name) do
    name = get_in(run_object, ["metadata", "name"])
    status = decode_run_status(run_object)

    cond do
      status.phase == :failed ->
        :failed

      true ->
        case effective_plan(run_object) do
          {:ok, []} -> :in_progress
          {:ok, plan} -> plan_outcome(name, plan, runner_job_status_by_name)
          {:error, _reason} -> :failed
        end
    end
  end

  defp plan_outcome(run_name, plan, runner_job_status_by_name) do
    run_ulid = run_ulid_of(run_name)

    job_statuses =
      Enum.map(plan, fn job ->
        Map.get(runner_job_status_by_name, Naming.child_name(run_ulid, job.key))
      end)

    cond do
      Enum.all?(job_statuses, &job_success?/1) -> :succeeded
      Enum.any?(job_statuses, &job_failed?/1) -> :failed
      true -> :in_progress
    end
  end

  defp job_success?(%RunnerJobStatus{phase: :completed, result: "success"}), do: true
  defp job_success?(_other), do: false

  defp job_failed?(%RunnerJobStatus{phase: :completed, result: result}) when result != "success",
    do: true

  defp job_failed?(_other), do: false

  defp count_cache_hits(run_objects) do
    run_objects
    |> Enum.map(&decode_run_status/1)
    |> Enum.flat_map(fn status -> Map.values(status.jobs) end)
    |> Enum.count(fn job -> Map.get(job.outputs, "cacheResult") == "hit" end)
  end

  defp count_archive_gaps(blob_root, scene_ulid, run_objects, runner_job_status_by_name) do
    run_objects
    |> Enum.flat_map(fn run_object ->
      case effective_plan(run_object) do
        {:ok, plan} ->
          run_ulid = run_ulid_of(get_in(run_object, ["metadata", "name"]))
          Enum.map(plan, &Naming.child_name(run_ulid, &1.key))

        {:error, _reason} ->
          []
      end
    end)
    |> Enum.filter(fn child_name ->
      job_success?(Map.get(runner_job_status_by_name, child_name))
    end)
    |> Enum.count(fn child_name ->
      {gapless?, _count} = LogVerifier.verify(blob_root, scene_ulid, [child_name])
      not gapless?
    end)
  end

  defp count_records(history, kind, predicate) do
    Enum.count(history, fn record -> record.kind == kind and predicate.(record) end)
  end

  defp first_field(history, kind, field, default) do
    Enum.find_value(history, default, fn record ->
      if record.kind == kind, do: Map.get(record, field)
    end)
  end

  defp sum_field(history, kind, field) do
    history
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&Map.get(&1, field, 0))
    |> Enum.sum()
  end

  defp decode_run_status(run_object) do
    case WorkflowRunStatus.from_wire(Map.get(run_object, "status", %{})) do
      {:ok, status} -> status
      {:error, _reason} -> WorkflowRunStatus.new(%{})
    end
  end

  defp decode_runner_job_status(object) do
    case RunnerJobStatus.from_wire(Map.get(object, "status", %{})) do
      {:ok, status} -> status
      {:error, _reason} -> %RunnerJobStatus{phase: :queued}
    end
  end

  defp acquisition_count(object) do
    case object |> Map.get("status", %{}) |> Map.get("acquisitionCount", 0) do
      count when is_integer(count) and count >= 0 -> count
      _other -> 0
    end
  end

  defp run_ulid_of("run-" <> ulid), do: ulid
  defp run_ulid_of(_other), do: ""

  # -- Engine plan-from-definition (same pipeline as MultiRunController) -------

  defp effective_plan(run_object) do
    SimRunner.Scene.SceneRunner.MultiRunController.effective_plan(run_object)
  end

  # -- Teardown / summary ------------------------------------------------------

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp print_summary_table(%Scoreboard{} = scoreboard, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_ms

    IO.puts("""
    == crest-ci demo scene: final scoreboard (t+#{div(elapsed_ms, 1000)}s) ==
      runs_succeeded          #{scoreboard.runs_succeeded}
      runs_failed             #{scoreboard.runs_failed}
      duplicate_acquisitions  #{scoreboard.duplicate_acquisitions}
      controller_failovers    #{scoreboard.controller_failovers}
      failover_gap_ms         #{scoreboard.controller_failover_gap_ms}
      gateway_failovers       #{scoreboard.gateway_failovers}
      rehomed_runners         #{scoreboard.rehomed_runners}
      archive_gaps            #{scoreboard.archive_gaps}
      cache_hits              #{scoreboard.cache_hits}
    """)
  end

  defmodule MultiRunController do
    @moduledoc """
    Private collaborator: reconciles EVERY non-terminal `WorkflowRun` in
    the namespace, generalizing `SimRunner.Demo.ControllerInstance` (which
    reconciles exactly one hardcoded run) from one run to N — see
    `SimRunner.Scene.SceneRunner`'s moduledoc for why the single-run
    harness collaborator cannot be reused directly for a scene.

    Composes the same real collaborators `ControllerInstance` does
    (`CrestCiController.LeaderElector`, `.LeaseSweeper`, `.NeedsResolver`,
    the Engine `WorkflowParser` -> `GithubContext` -> `Planner` pipeline),
    via the same `Module.concat/1` + `apply/3` dodge, for the same reason:
    no compile-time in-umbrella dependency on `crest_ci_controller` is
    possible from `sim_runner` without creating a cycle.

    Only the elected leader reconciles or sweeps; standbys contend for the
    Lease and do nothing else. A `WorkflowRun` whose `workflowYaml` fails
    to expand (an unknown `needs` target, a `needs` cycle, or any other
    `CrestCiController.Engine.Planner` error) is marked `Failed` with the
    structured error recorded — the
    `applicationService.Controller.PlanFromDefinition` contract this
    session's later wave will land for real.
    """

    use GenServer

    require Logger

    alias CrestCiContract.{JobStatus, WorkflowRunSpec, WorkflowRunStatus}
    alias SimRunner.Demo.{Naming, WorkflowRunProjector}

    @leader_elector Module.concat([CrestCiController, LeaderElector])
    @lease_sweeper Module.concat([CrestCiController, LeaseSweeper])
    @needs_resolver Module.concat([CrestCiController, NeedsResolver])
    @workflow_parser Module.concat([CrestCiController, Engine, WorkflowParser])
    @github_context Module.concat([CrestCiController, Engine, GithubContext])
    @planner Module.concat([CrestCiController, Engine, Planner])

    @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
    @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
    @pod_gvk {"core", "v1", "Pod"}
    @namespace "default"

    defmodule State do
      @moduledoc false
      @enforce_keys [:kube_conn, :elector, :reconcile_interval_ms]
      defstruct [:kube_conn, :elector, :reconcile_interval_ms, is_leader: false]
    end

    @doc """
    Starts one multi-run controller instance.

    Options: `:kube_conn` (required), `:identity` (required, this
    instance's Lease-holder identity), `:election_timings` (required,
    passed straight to `CrestCiController.LeaderElector.start_link/3`),
    `:reconcile_interval_ms` (defaults to `30`).
    """
    @spec start_link(keyword()) :: {:ok, pid()}
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      kube_conn = Keyword.fetch!(opts, :kube_conn)
      identity = Keyword.fetch!(opts, :identity)
      election_timings = Keyword.fetch!(opts, :election_timings)
      reconcile_interval_ms = Keyword.get(opts, :reconcile_interval_ms, 30)

      {:ok, elector} =
        apply(@leader_elector, :start_link, [kube_conn, identity, election_timings])

      :ok = apply(@leader_elector, :subscribe, [elector, self()])

      state = %State{
        kube_conn: kube_conn,
        elector: elector,
        reconcile_interval_ms: reconcile_interval_ms
      }

      schedule_tick(reconcile_interval_ms)
      {:ok, state}
    end

    @impl true
    def handle_info({:leader_acquired, _identity}, state),
      do: {:noreply, %{state | is_leader: true}}

    def handle_info({:leader_lost, _identity}, state), do: {:noreply, %{state | is_leader: false}}

    def handle_info(:tick, state) do
      if state.is_leader do
        reconcile_once(state)
        apply(@lease_sweeper, :sweep, [state.kube_conn])
      end

      schedule_tick(state.reconcile_interval_ms)
      {:noreply, state}
    end

    defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

    # -- Reconciliation: every non-terminal WorkflowRun, not just one ---------

    defp reconcile_once(state) do
      case kube_list(state, @workflow_run_gvk) do
        {:ok, run_objects} ->
          Enum.each(run_objects, &reconcile_run(state, &1))

        {:error, reason} ->
          Logger.warning("SceneRunner controller: list failed: #{inspect(reason)}")
      end
    end

    defp reconcile_run(state, run_object) do
      name = get_in(run_object, ["metadata", "name"])

      with {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(run_object, "status", %{})),
           false <- CrestCiContract.WorkflowRunPhase.terminal?(status.phase) do
        case __MODULE__.effective_plan(run_object) do
          {:ok, plan} -> apply_plan(state, name, plan, status)
          {:error, reason} -> mark_run_failed(state, name, inspect(reason))
        end
      else
        _terminal_or_undecodable -> :ok
      end
    end

    defp apply_plan(state, name, plan, status) do
      run_ulid = run_ulid_of(name)
      proposal = apply(@needs_resolver, :resolve, [plan, status.jobs])
      Enum.each(proposal.runnable_job_keys, &create_child(state, name, run_ulid, plan, &1))
      skip_jobs(state, name, proposal.skip_job_keys)
      :ok
    end

    # -- Engine plan-from-definition (public: reused by SceneRunner's own
    # verification pass so both derive the SAME plan for the SAME run) ------

    @doc false
    @spec effective_plan(map()) :: {:ok, [CrestCiContract.PlanJob.t()]} | {:error, term()}
    def effective_plan(run_object) do
      spec_wire = Map.get(run_object, "spec", %{})

      with {:ok, spec} <- WorkflowRunSpec.from_wire(spec_wire) do
        workflow_yaml = Map.get(spec_wire, "workflowYaml", "")

        case {spec.plan, workflow_yaml} do
          {[], yaml} when is_binary(yaml) and yaml != "" -> plan_from_definition(yaml, spec)
          {plan, _yaml} -> {:ok, plan}
        end
      end
    end

    defp plan_from_definition(workflow_yaml, %WorkflowRunSpec{} = spec) do
      with {:ok, definition, _warnings} <- apply(@workflow_parser, :parse, [workflow_yaml]),
           {:ok, github_context} <-
             apply(@github_context, :new, [
               %{
                 actor: "",
                 event: %{},
                 event_name: "push",
                 ref: spec.ref,
                 repository: spec.repo,
                 sha: spec.sha
               }
             ]),
           {:ok, plan} <- apply(@planner, :plan, [definition, github_context]) do
        {:ok, plan}
      else
        {:error, reason} -> {:error, {:plan_from_definition_failed, reason}}
      end
    end

    defp mark_run_failed(state, name, reason) do
      WorkflowRunProjector.patch(state.kube_conn, name, fn status ->
        WorkflowRunStatus.mark_plan_failed(status, reason)
      end)

      :ok
    end

    defp create_child(state, run_name, run_ulid, plan, job_key) do
      job = Enum.find(plan, &(&1.key == job_key))
      child_name = Naming.child_name(run_ulid, job_key)
      runs_on = if job.runs_on in [nil, []], do: ["default"], else: job.runs_on

      runner_job_object = %{
        "apiVersion" => "ci.crest.dev/v1alpha1",
        "kind" => "RunnerJob",
        "metadata" => %{"name" => child_name, "namespace" => @namespace},
        "spec" => %{
          "runRef" => run_ulid,
          "jobKey" => job_key,
          "runsOn" => runs_on,
          "jobMessage" => %{"jobName" => child_name, "steps" => job.steps, "result" => "success"}
        },
        "status" => %{
          "phase" => "Queued",
          "leasedBy" => "",
          "leaseExpiresAt" => "",
          "acquiredAt" => "",
          "result" => "",
          "acquisitionCount" => 0
        }
      }

      tolerate_already_exists(kube_create(state, @runner_job_gvk, runner_job_object))

      pod_object = %{
        "apiVersion" => "v1",
        "kind" => "Pod",
        "metadata" => %{
          "name" => child_name,
          "namespace" => @namespace,
          "ownerReferences" => [
            %{
              "apiVersion" => "ci.crest.dev/v1alpha1",
              "kind" => "RunnerJob",
              "name" => child_name,
              "uid" => child_name
            }
          ]
        },
        "spec" => %{
          "jitConfig" => %{"runnerName" => "runner-#{child_name}", "jobName" => child_name}
        }
      }

      tolerate_already_exists(kube_create(state, @pod_gvk, pod_object))
      mark_queued(state, run_name, job_key)
    end

    defp tolerate_already_exists({:ok, _object}), do: :ok
    defp tolerate_already_exists({:error, :already_exists}), do: :ok

    defp tolerate_already_exists({:error, reason}) do
      Logger.warning("SceneRunner controller: create failed: #{inspect(reason)}")
      :ok
    end

    defp mark_queued(state, run_name, job_key) do
      WorkflowRunProjector.patch(state.kube_conn, run_name, fn status ->
        case Map.get(status.jobs, job_key) do
          %JobStatus{phase: :waiting} = existing ->
            {:ok, updated} = JobStatus.update(existing, %{phase: :queued, queued_at: iso_now()})
            WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, updated))

          nil ->
            {:ok, fresh} = JobStatus.new(%{phase: :queued, queued_at: iso_now()})
            WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, fresh))

          _already_progressed ->
            status
        end
      end)
    end

    defp skip_jobs(_state, _run_name, []), do: :ok

    defp skip_jobs(state, run_name, job_keys) do
      WorkflowRunProjector.patch(state.kube_conn, run_name, fn status ->
        updated_jobs =
          Enum.reduce(job_keys, status.jobs, fn job_key, jobs_acc ->
            {:ok, skipped} = JobStatus.new(%{phase: :skipped, finished_at: iso_now()})
            Map.put(jobs_acc, job_key, skipped)
          end)

        WorkflowRunStatus.update_jobs(status, updated_jobs)
      end)
    end

    defp kube_list(%State{kube_conn: {module, conn}}, gvk),
      do: list_all(module, conn, gvk, nil, [])

    defp list_all(module, conn, gvk, continue, acc) do
      opts = if continue, do: [continue: continue], else: []

      case module.list(conn, gvk, @namespace, opts) do
        {:ok, objects, nil} -> {:ok, acc ++ objects}
        {:ok, objects, next} -> list_all(module, conn, gvk, next, acc ++ objects)
        {:error, reason} -> {:error, reason}
      end
    end

    defp kube_create(%State{kube_conn: {module, conn}}, gvk, object),
      do: module.create(conn, gvk, @namespace, object)

    defp run_ulid_of("run-" <> ulid), do: ulid
    defp run_ulid_of(_other), do: ""

    defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
