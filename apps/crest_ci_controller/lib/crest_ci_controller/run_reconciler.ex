defmodule CrestCiController.RunReconciler do
  @moduledoc """
  Leader-only, level-triggered reconciler: turns each non-terminal
  `WorkflowRun`'s pre-expanded plan into `RunnerJob` (+ owning pod) child
  resources, absorbs completed `RunnerJob` results back into the parent
  run's per-job status, and aggregates the run's own terminal phase once
  every plan job is terminal.

  Every decision about *which* jobs are runnable or must be skipped comes
  from the pure `CrestCiController.NeedsResolver.resolve/2` — this module
  only turns that proposal into `CrestCiContract.KubeClient` side effects
  (409-tolerant `create`s for deterministically-named children, CAS'd
  `patch_status` writes for the run's own status subresource) and holds no
  authoritative state of its own: a poll tick reads the world fresh from
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
    JobKey,
    JobStatus,
    PlanJob,
    RunnerJobSpec,
    RunnerJobStatus,
    WorkflowRunPhase,
    WorkflowRunSpec,
    WorkflowRunStatus
  }

  alias CrestCiController.NeedsResolver

  @typedoc "`{adapter_module, adapter_conn}` — see moduledoc."
  @type kube_conn :: {module(), term()}

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @pod_gvk {"core", "v1", "Pod"}

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

  # -- Reconciliation ---------------------------------------------------------

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
        proposal = NeedsResolver.resolve(spec.plan, status.jobs)

        jobs =
          status.jobs
          |> mark_skipped(proposal.skip_job_keys)
          |> create_runner_jobs(state, name, spec.plan, proposal.runnable_job_keys)
          |> absorb_runner_job_results(state, name)

        new_status = WorkflowRunStatus.update_jobs(status, jobs)
        maybe_patch_run_status(state, name, run_object, status, new_status)
      end
    else
      {:error, reason} ->
        Logger.warning("RunReconciler: failed to decode WorkflowRun #{name}: #{inspect(reason)}")
    end
  end

  defp maybe_patch_run_status(_state, _name, _run_object, status, status), do: :ok

  defp maybe_patch_run_status(state, name, run_object, _old_status, new_status) do
    resource_version = get_in(run_object, ["metadata", "resourceVersion"])

    case kube_patch_status(
           state,
           @workflow_run_gvk,
           name,
           WorkflowRunStatus.to_wire(new_status),
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

  # -- Job status transitions --------------------------------------------------

  defp mark_skipped(jobs, skip_job_keys) do
    Enum.reduce(skip_job_keys, jobs, fn key, acc ->
      Map.put(acc, key, updated_job_status(Map.get(acc, key), :skipped))
    end)
  end

  defp create_runner_jobs(jobs, state, run_name, plan, runnable_job_keys) do
    Enum.reduce(runnable_job_keys, jobs, fn key, acc ->
      case Enum.find(plan, &(&1.key == key)) do
        %PlanJob{} = plan_job ->
          ensure_runner_job(state, run_name, plan_job)
          ensure_pod(state, run_name, plan_job)
          Map.put(acc, key, updated_job_status(Map.get(acc, key), :queued))

        nil ->
          acc
      end
    end)
  end

  # Reflects a completed RunnerJob's result back onto its owning job entry.
  # Only ever inspects jobs this reconciler itself queued (i.e. for which a
  # deterministically-named RunnerJob exists) — every other phase is left
  # untouched here.
  defp absorb_runner_job_results(jobs, state, run_name) do
    Map.new(jobs, fn {key, %JobStatus{phase: phase} = job_status} ->
      if phase == :queued do
        {key, absorb_result(state, child_name(run_name, key), job_status)}
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

  defp updated_job_status(nil, phase) do
    {:ok, job_status} = JobStatus.new(%{phase: phase})
    job_status
  end

  defp updated_job_status(%JobStatus{} = current, phase) do
    case JobStatus.update(current, %{phase: phase}) do
      {:ok, updated} -> updated
      {:error, _reason} -> current
    end
  end

  # -- Child creation (deterministic naming; 409 AlreadyExists is success) ---

  defp ensure_runner_job(state, run_name, %PlanJob{} = plan_job) do
    child = child_name(run_name, plan_job.key)
    runs_on = if plan_job.runs_on == [], do: ["default"], else: plan_job.runs_on

    with {:ok, runner_job_spec} <-
           RunnerJobSpec.new(%{
             job_key: plan_job.key,
             run_ref: run_name,
             runs_on: runs_on,
             job_message: %{"steps" => plan_job.steps}
           }),
         {:ok, runner_job_status} <- RunnerJobStatus.new(%{}) do
      object = %{
        "metadata" => %{
          "name" => child,
          "ownerReferences" => [owner_reference("ci.crest.dev/v1alpha1", "WorkflowRun", run_name)]
        },
        "spec" => RunnerJobSpec.to_wire(runner_job_spec),
        "status" => RunnerJobStatus.to_wire(runner_job_status)
      }

      case kube_create(state, @runner_job_gvk, object) do
        {:ok, _created} ->
          :ok

        {:error, :already_exists} ->
          :ok

        {:error, reason} ->
          Logger.warning("RunReconciler: failed to create RunnerJob #{child}: #{inspect(reason)}")
      end
    end
  end

  defp ensure_pod(state, run_name, %PlanJob{} = plan_job) do
    runner_job_name = child_name(run_name, plan_job.key)
    pod_name = runner_job_name <> "-pod"

    object = %{
      "metadata" => %{
        "name" => pod_name,
        "ownerReferences" => [
          owner_reference("ci.crest.dev/v1alpha1", "RunnerJob", runner_job_name)
        ]
      },
      "spec" => %{}
    }

    case kube_create(state, @pod_gvk, object) do
      {:ok, _created} ->
        :ok

      {:error, :already_exists} ->
        :ok

      {:error, reason} ->
        Logger.warning("RunReconciler: failed to create Pod #{pod_name}: #{inspect(reason)}")
    end
  end

  defp owner_reference(api_version, kind, name),
    do: %{"apiVersion" => api_version, "kind" => kind, "name" => name, "uid" => name}

  defp child_name(run_name, job_key), do: "#{run_name}-#{JobKey.slug(job_key)}"

  # -- Injected KubeClient adapter dispatch ------------------------------

  defp kube_list(%State{kube_conn: {module, conn}, namespace: ns}, gvk, opts),
    do: module.list(conn, gvk, ns, opts)

  defp kube_get(%State{kube_conn: {module, conn}, namespace: ns}, gvk, name),
    do: module.get(conn, gvk, ns, name)

  defp kube_create(%State{kube_conn: {module, conn}, namespace: ns}, gvk, object),
    do: module.create(conn, gvk, ns, object)

  defp kube_patch_status(%State{kube_conn: {module, conn}, namespace: ns}, gvk, name, status, rv),
    do: module.patch_status(conn, gvk, ns, name, status, rv)
end
