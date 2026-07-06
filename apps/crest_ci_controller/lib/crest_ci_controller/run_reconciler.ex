defmodule CrestCiController.RunReconciler do
  @moduledoc """
  Leader-only, level-triggered reconciler: turns each non-terminal
  `WorkflowRun`'s pre-expanded plan into `RunnerJob` (+ owning pod) child
  resources, absorbs completed `RunnerJob` results back into the parent
  run's per-job status, and aggregates the run's own terminal phase once
  every plan job is terminal.

  Every decision about *which* jobs are runnable or must be skipped, and
  every child-creation / status-patch command that follows from that
  decision, is computed by the pure `CrestCiController.ReconcilePlanner.plan/2`
  (which itself delegates runnable/skip classification to
  `CrestCiController.NeedsResolver.resolve/2`). This module's own
  responsibility is narrower than the planner's: it is the only place that
  turns `ReconcilePlanner`'s command list into `CrestCiContract.KubeClient`
  side effects (409-tolerant `create`s for deterministically-named
  children, CAS'd `patch_status` writes for the run's own status
  subresource), and the only place that performs the one piece of I/O the
  pure planner cannot do itself: reading a queued job's owning `RunnerJob`
  back to see whether it has reached a terminal result yet. It holds no
  authoritative state of its own — a poll tick reads the world fresh from
  the Kubernetes API every time, so a crash-and-restart (or, in this
  suite, a `Process.exit(pid, :kill)` mid-flight) converges from whatever
  the surviving/incoming leader observes next, with no local recovery
  path required.

  Only ticks when `leader_elector` (a `CrestCiController.LeaderElector`
  pid) reports `leader?/1` true — non-leaders keep polling but never
  write, so at most one replica's reconciler executes side effects at a
  time, per the coordination-Lease invariant.

  `kube_conn` is `{adapter_module, adapter_conn}` — the concrete
  `CrestCiContract.KubeClient` adapter is injected by the caller, never
  hardcoded here, so this reconciler is substitutable across the real
  adapter, the mock-k8s HTTP adapter, or any test double without a single
  line changing (Dependency Inversion).
  """

  use GenServer

  require Logger

  alias CrestCiContract.{
    DeterministicNaming,
    JobStatus,
    RunnerJobStatus,
    WorkflowRunPhase,
    WorkflowRunSpec,
    WorkflowRunStatus
  }

  alias CrestCiController.ReconcilePlanner

  @typedoc "`{adapter_module, adapter_conn}` — see moduledoc."
  @type kube_conn :: {module(), term()}

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @pod_gvk {"core", "v1", "Pod"}
  @workflow_run_kind "WorkflowRun"

  @default_namespace "default"
  @default_poll_interval_ms 200

  defmodule State do
    @moduledoc false
    @enforce_keys [:kube_conn, :leader_elector, :namespace, :poll_interval_ms]
    defstruct [:kube_conn, :leader_elector, :namespace, :poll_interval_ms]
  end

  # -- Client API ------------------------------------------------------------

  @doc """
  Starts a `RunReconciler`. `leader_elector` is the pid of a
  `CrestCiController.LeaderElector` this reconciler defers to — it only
  executes side effects on a tick where that pid reports it currently
  holds the coordination Lease.

  `opts` (all optional):
    * `:namespace` — namespace `WorkflowRun`/`RunnerJob`/`Pod` objects live
      in (default `"default"`)
    * `:poll_interval_ms` — how often to reconcile (default `200`)
  """
  @spec start_link(kube_conn(), pid(), map()) :: {:ok, pid()}
  def start_link(kube_conn, leader_elector, opts \\ %{}) do
    GenServer.start_link(__MODULE__, {kube_conn, leader_elector, opts})
  end

  @doc """
  Reconciles one `WorkflowRun`: runs `ReconcilePlanner.plan/2` against
  `workflow_run` and the deterministic `RunnerJob` names already known to
  exist (`existing_runner_jobs`), then executes every returned command
  against `kube_conn` — the sole seam where the pure planner's command
  list meets `CrestCiContract.KubeClient`.

  `workflow_run` is `ReconcilePlanner.workflow_run()` (`:ulid`, `:run_ref`,
  `:plan`, optional `:job_statuses`/`:phase`), extended with two optional
  keys this reconciler itself reads and `ReconcilePlanner.plan/2` simply
  ignores: `:resource_version` — the run object's current
  `metadata.resourceVersion`, used to CAS the `patch_status` write a
  `{:patch_status, _}` command may produce — and `:namespace` (defaults to
  `"default"` when absent), so a `RunReconciler` instance's own configured
  namespace (never a global) is honored even though `ReconcilePlanner`'s
  command shapes carry no namespace of their own. A `create` that comes
  back `{:error, :already_exists}` is a no-op (deterministic naming
  already makes it one); a `patch_status` that comes back `{:error,
  :conflict}` is left alone — another writer moved the run first, and the
  next tick re-reads fresh state and re-derives from there rather than
  forcing a stale write.

  Always returns `:ok`: every command is executed independently and a
  failure on one is logged, never raised, so one bad command cannot stop
  the rest of the tick (or the next tick, which simply re-observes
  whatever didn't converge).
  """
  @spec reconcile(
          kube_conn(),
          ReconcilePlanner.workflow_run(),
          ReconcilePlanner.existing_runner_jobs()
        ) ::
          :ok
  def reconcile(kube_conn, workflow_run, existing_runner_jobs)
      when is_map(workflow_run) and is_list(existing_runner_jobs) do
    workflow_run
    |> ReconcilePlanner.plan(existing_runner_jobs)
    |> Enum.each(&execute_command(kube_conn, workflow_run, &1))

    :ok
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init({kube_conn, leader_elector, opts}) do
    state = %State{
      kube_conn: kube_conn,
      leader_elector: leader_elector,
      namespace: Map.get(opts, :namespace, @default_namespace),
      poll_interval_ms: Map.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if leading?(state) do
      reconcile_all(state)
    end

    Process.send_after(self(), :tick, state.poll_interval_ms)
    {:noreply, state}
  end

  defp leading?(%State{leader_elector: pid}) do
    Process.alive?(pid) and CrestCiController.LeaderElector.leader?(pid)
  end

  # -- Per-tick orchestration: observe, absorb, then plan+execute -------------

  defp reconcile_all(state) do
    case kube_list(state, @workflow_run_gvk, []) do
      {:ok, runs, _continue} ->
        Enum.each(runs, &reconcile_run(state, &1))

      {:error, reason} ->
        Logger.warning("RunReconciler: failed to list WorkflowRuns: #{inspect(reason)}")
    end
  end

  defp reconcile_run(state, run_object) do
    name = get_in(run_object, ["metadata", "name"])

    with {:ok, spec} <- WorkflowRunSpec.from_wire(Map.get(run_object, "spec", %{})),
         {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(run_object, "status", %{})) do
      if WorkflowRunPhase.terminal?(status.phase) do
        :ok
      else
        {job_statuses, run_object, status} =
          absorb_and_persist(state, name, run_object, status)

        workflow_run = %{
          ulid: name,
          run_ref: name,
          plan: spec.plan,
          job_statuses: job_statuses,
          phase: status.phase,
          resource_version: get_in(run_object, ["metadata", "resourceVersion"]),
          namespace: state.namespace
        }

        reconcile(state.kube_conn, workflow_run, existing_runner_job_names(state, name))
      end
    else
      {:error, reason} ->
        Logger.warning("RunReconciler: failed to decode WorkflowRun #{name}: #{inspect(reason)}")
    end
  end

  # `ReconcilePlanner.plan/2` is pure and only ever proposes skip/queue
  # transitions on top of whatever `job_statuses` it is handed — it has no
  # way to observe a `RunnerJob`'s own completion, so this reconciler reads
  # that back itself (the one I/O step the planner cannot do) and, when it
  # changes anything, persists it as its own CAS'd `patch_status` write
  # *before* handing the resulting `job_statuses` to `reconcile/3`. Folding
  # the absorption straight into the planner's input without persisting it
  # first would make the planner's own no-op comparison (against that same
  # input) blind to the absorption — this two-step order is what keeps both
  # writes real.
  defp absorb_and_persist(state, run_name, run_object, status) do
    absorbed_jobs = absorb_runner_job_results(state, run_name, status.jobs)

    if absorbed_jobs == status.jobs do
      {status.jobs, run_object, status}
    else
      new_status = WorkflowRunStatus.update_jobs(status, absorbed_jobs)
      resource_version = get_in(run_object, ["metadata", "resourceVersion"])

      case kube_patch_status(
             state,
             @workflow_run_gvk,
             run_name,
             WorkflowRunStatus.to_wire(new_status),
             resource_version
           ) do
        {:ok, updated_object} ->
          {new_status.jobs, updated_object, new_status}

        {:error, :conflict} ->
          # Another writer moved this run's status first; the next tick
          # re-reads fresh state (including this absorption) and retries.
          {status.jobs, run_object, status}

        {:error, reason} ->
          Logger.warning(
            "RunReconciler: failed to persist absorbed job results for #{run_name}: #{inspect(reason)}"
          )

          {status.jobs, run_object, status}
      end
    end
  end

  # Reflects a completed RunnerJob's result back onto its owning job entry.
  # Only ever inspects jobs already `:queued` (i.e. for which a
  # deterministically-named RunnerJob exists) — every other phase is left
  # untouched here.
  defp absorb_runner_job_results(state, run_name, jobs) do
    Map.new(jobs, fn {key, %JobStatus{phase: phase} = job_status} ->
      if phase == :queued do
        child_name = DeterministicNaming.runner_job_name(run_name, key)
        {key, absorb_result(state, child_name, job_status)}
      else
        {key, job_status}
      end
    end)
  end

  defp absorb_result(state, child_name, job_status) do
    case kube_get(state, @runner_job_gvk, child_name) do
      {:ok, runner_job} ->
        case RunnerJobStatus.from_wire(Map.get(runner_job, "status", %{})) do
          {:ok, %RunnerJobStatus{phase: :completed, result: "success"}} ->
            updated_job_status(job_status, :succeeded)

          {:ok, %RunnerJobStatus{phase: :completed}} ->
            updated_job_status(job_status, :failed)

          {:ok, %RunnerJobStatus{phase: :abandoned}} ->
            updated_job_status(job_status, :failed)

          _not_yet_terminal ->
            job_status
        end

      {:error, _reason} ->
        job_status
    end
  end

  defp updated_job_status(%JobStatus{} = current, phase) do
    case JobStatus.update(current, %{phase: phase}) do
      {:ok, updated} -> updated
      {:error, _reason} -> current
    end
  end

  # The deterministic `RunnerJob` names already known to exist for this run
  # — used only so `ReconcilePlanner.plan/2` can suppress redundant create
  # commands for jobs whose child already landed (e.g. a create succeeded
  # on a previous tick whose own status patch then lost a CAS race).
  # Correctness does not depend on this list being exhaustive: a `create`
  # for a name that already exists is a no-op regardless
  # (`{:error, :already_exists}` is absorbed below), this is purely an
  # idempotent-replanning optimization.
  defp existing_runner_job_names(state, run_ulid) do
    case kube_list(state, @runner_job_gvk, []) do
      {:ok, objects, _continue} ->
        objects
        |> Enum.filter(&owned_by_run?(&1, run_ulid))
        |> Enum.map(&get_in(&1, ["metadata", "name"]))

      {:error, _reason} ->
        []
    end
  end

  defp owned_by_run?(object, run_ulid) do
    case get_in(object, ["metadata", "ownerReferences"]) do
      [%{"kind" => @workflow_run_kind, "name" => ^run_ulid} | _rest] -> true
      _other -> false
    end
  end

  # -- Executing ReconcilePlanner's commands (409/CAS-tolerant) ---------------

  defp execute_command(kube_conn, workflow_run, {:create_runner_job, cmd}) do
    object = %{
      "metadata" => %{
        "name" => cmd.name,
        "ownerReferences" => [owner_reference(cmd.owner_ref)]
      },
      "spec" => CrestCiContract.RunnerJobSpec.to_wire(cmd.runner_job_spec),
      "status" => RunnerJobStatus.to_wire(default_runner_job_status())
    }

    create_idempotent(kube_conn, namespace_of(workflow_run), @runner_job_gvk, cmd.name, object)
  end

  defp execute_command(kube_conn, workflow_run, {:create_pod, cmd}) do
    object = %{
      "metadata" => %{
        "name" => cmd.name,
        "ownerReferences" => [owner_reference(cmd.owner_ref)]
      },
      "spec" => %{}
    }

    create_idempotent(kube_conn, namespace_of(workflow_run), @pod_gvk, cmd.name, object)
  end

  defp execute_command(kube_conn, workflow_run, {:patch_status, cmd}) do
    name = Map.fetch!(workflow_run, :ulid)
    namespace = namespace_of(workflow_run)
    resource_version = Map.get(workflow_run, :resource_version)
    status_wire = WorkflowRunStatus.to_wire(%WorkflowRunStatus{jobs: cmd.jobs, phase: cmd.phase})

    case kube_patch_status(
           kube_conn,
           namespace,
           @workflow_run_gvk,
           name,
           status_wire,
           resource_version
         ) do
      {:ok, _updated} ->
        :ok

      {:error, :conflict} ->
        # Another writer moved this run's status first; the next tick
        # re-reads fresh state and re-derives from there.
        :ok

      {:error, reason} ->
        Logger.warning(
          "RunReconciler: failed to patch WorkflowRun #{name} status: #{inspect(reason)}"
        )
    end
  end

  defp namespace_of(workflow_run), do: Map.get(workflow_run, :namespace, @default_namespace)

  defp default_runner_job_status do
    {:ok, status} = RunnerJobStatus.new(%{})
    status
  end

  defp create_idempotent(kube_conn, namespace, gvk, name, object) do
    case kube_create(kube_conn, namespace, gvk, object) do
      {:ok, _created} ->
        :ok

      {:error, :already_exists} ->
        :ok

      {:error, reason} ->
        Logger.warning("RunReconciler: failed to create #{name}: #{inspect(reason)}")
    end
  end

  defp owner_reference(%{api_version: api_version, kind: kind, name: name}),
    do: %{"apiVersion" => api_version, "kind" => kind, "name" => name, "uid" => name}

  # -- Injected KubeClient adapter dispatch ------------------------------
  #
  # The tick loop dispatches through `%State{}` (which already carries this
  # instance's configured namespace); `reconcile/3` dispatches through a
  # bare `kube_conn()` plus an explicit `namespace` threaded from
  # `workflow_run` (see `namespace_of/1`) — `reconcile/3`'s own contract
  # takes no namespace argument, so it travels as an (ignored-by-the-
  # planner) key on `workflow_run` instead of ever falling back to a
  # hardcoded default silently.

  defp kube_list(%State{kube_conn: {module, conn}, namespace: ns}, gvk, opts),
    do: module.list(conn, gvk, ns, opts)

  defp kube_get(%State{kube_conn: {module, conn}, namespace: ns}, gvk, name),
    do: module.get(conn, gvk, ns, name)

  defp kube_patch_status(%State{kube_conn: {module, conn}, namespace: ns}, gvk, name, status, rv),
    do: module.patch_status(conn, gvk, ns, name, status, rv)

  defp kube_create({module, conn}, namespace, gvk, object),
    do: module.create(conn, gvk, namespace, object)

  defp kube_patch_status({module, conn}, namespace, gvk, name, status, rv),
    do: module.patch_status(conn, gvk, namespace, name, status, rv)
end
