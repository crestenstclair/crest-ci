defmodule CrestCiController.LeaseSweeper do
  @moduledoc """
  Periodically scans `RunnerJob` objects and reclaims leases that have
  fallen out of sync with reality — the controller-only edges of the
  `RunnerJobPhase` machine:

    * `Leased` past `leaseExpiresAt` with no acquisition -> back to
      `Queued`, so the job is re-deliverable to another runner.
    * `Acquired` whose lease heartbeat has lapsed (`leaseExpiresAt` in the
      past with no completion) -> `Abandoned`, and the owning
      `WorkflowRun`'s job entry is marked `Failed`.

  These are the two transitions the `RunnerJobPhase` machine reserves for
  the controller sweeper alone (`Leased -> Queued` and
  `{Leased, Acquired} -> Abandoned`); the gateway never performs them,
  which is what keeps the phase machine auditable to a single owner per
  transition.

  `sweep/1` is a single, level-triggered pass: it lists the current state
  of the world, decides transitions purely from what it observes right
  now, and applies them. It is safe to call repeatedly and concurrently —
  every write goes through `patch_status/6` compare-and-swapped against
  the resourceVersion last observed for that object, and a lost CAS
  (`{:error, :conflict}`) means some other actor (another sweep pass, the
  gateway leasing the job, or the runner completing it) already moved the
  object; this pass re-reads fresh state and re-evaluates rather than
  forcing the write, so it converges instead of duplicating or
  clobbering work. Nothing here is retained across calls — there is no
  process, no state to reconstruct after a crash, and no ETS/Agent —
  `sweep/1` reads and writes only through the Kubernetes API port.

  ## `kube_conn`

  A `kube_conn` is `{client_module, conn}`: `client_module` is any module
  implementing `CrestCiContract.KubeClient`, and `conn` is that module's
  own opaque connection handle. Bundling the two together is what lets
  `sweep/1` stay a single-argument, adapter-agnostic function (callers
  inject whichever adapter they want — a real `ReqKubeClient` in
  production, an in-memory fake in tests — without this module ever
  constructing or knowing about a concrete adapter itself).
  """

  alias CrestCiContract.{JobStatus, RunnerJobSpec, RunnerJobStatus, WorkflowRunStatus}

  require Logger

  @typedoc "A `CrestCiContract.KubeClient`-implementing module paired with its own opaque conn."
  @type kube_conn :: {module(), term()}

  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  # Bounded retry against optimistic-concurrency conflicts: re-read fresh
  # state and re-evaluate rather than forcing a stale write. If contention
  # is high enough to exhaust these, the next sweep pass (this is
  # level-triggered and idempotent) picks the object back up.
  @max_cas_attempts 3

  @doc """
  Run one sweep pass over every `RunnerJob` in the namespace, reclaiming
  expired leases and abandoning lapsed acquisitions. Always returns `:ok`
  — a transport failure listing or patching an individual object is
  logged and left for the next pass, since a sweep pass is not the sole
  writer of authoritative state and its absence for one cycle is not
  fatal.
  """
  @spec sweep(kube_conn()) :: :ok
  def sweep(kube_conn) do
    case kube_list(kube_conn, @runner_job_gvk, @namespace, []) do
      {:ok, objects, _continue_token} ->
        Enum.each(objects, fn object ->
          name = get_in(object, ["metadata", "name"])
          attempt_runner_job_transition(kube_conn, name, @max_cas_attempts)
        end)

        :ok

      {:error, reason} ->
        Logger.warning("LeaseSweeper: failed to list RunnerJobs: #{inspect(reason)}")
        :ok
    end
  end

  # Re-reads the RunnerJob fresh on every attempt (including the first) so
  # the decision is always made from the current resourceVersion, never a
  # possibly-stale snapshot from list/4.
  defp attempt_runner_job_transition(_kube_conn, _name, 0), do: :ok

  defp attempt_runner_job_transition(kube_conn, name, attempts_left) do
    with {:ok, object} <- kube_get(kube_conn, @runner_job_gvk, @namespace, name),
         {:ok, status} <- RunnerJobStatus.from_wire(Map.get(object, "status", %{})),
         {:ok, spec} <- RunnerJobSpec.from_wire(Map.get(object, "spec", %{})),
         {:to, new_phase} <- desired_transition(status) do
      new_status = transitioned_status(status, new_phase)
      resource_version = get_in(object, ["metadata", "resourceVersion"])

      case kube_patch_status(
             kube_conn,
             @runner_job_gvk,
             @namespace,
             name,
             RunnerJobStatus.to_wire(new_status),
             resource_version
           ) do
        {:ok, _updated} ->
          if new_phase == :abandoned do
            fail_owning_job(kube_conn, spec.run_ref, spec.job_key, @max_cas_attempts)
          else
            :ok
          end

        {:error, :conflict} ->
          attempt_runner_job_transition(kube_conn, name, attempts_left - 1)

        {:error, reason} ->
          Logger.warning("LeaseSweeper: failed to patch RunnerJob #{name}: #{inspect(reason)}")
          :ok
      end
    else
      :none ->
        :ok

      {:error, :not_found} ->
        # Deleted since list/4 observed it — nothing to reclaim.
        :ok

      {:error, reason} ->
        Logger.warning("LeaseSweeper: failed to read RunnerJob #{name}: #{inspect(reason)}")
        :ok
    end
  end

  # Pure decision: given the RunnerJob's current status, which of the two
  # sweeper-only edges (if any) applies right now.
  @spec desired_transition(RunnerJobStatus.t()) :: {:to, :queued | :abandoned} | :none
  defp desired_transition(%RunnerJobStatus{phase: :leased} = status) do
    if lease_expired?(status.lease_expires_at) and
         RunnerJobStatus.legal_transition?(:leased, :queued) do
      {:to, :queued}
    else
      :none
    end
  end

  defp desired_transition(%RunnerJobStatus{phase: :acquired} = status) do
    if lease_expired?(status.lease_expires_at) and
         RunnerJobStatus.legal_transition?(:acquired, :abandoned) do
      {:to, :abandoned}
    else
      :none
    end
  end

  defp desired_transition(_status), do: :none

  # Queued gets a fresh, cleared status (ready to be leased again).
  # Abandoned keeps the lease/acquisition audit trail — only the phase
  # changes.
  defp transitioned_status(_status, :queued) do
    {:ok, fresh} = RunnerJobStatus.new(%{phase: :queued})
    fresh
  end

  defp transitioned_status(status, :abandoned) do
    %{status | phase: :abandoned}
  end

  @spec lease_expired?(String.t()) :: boolean()
  defp lease_expired?(""), do: false

  defp lease_expired?(lease_expires_at) when is_binary(lease_expires_at) do
    case DateTime.from_iso8601(lease_expires_at) do
      {:ok, expires_at, _offset} -> DateTime.compare(expires_at, DateTime.utc_now()) == :lt
      {:error, _reason} -> false
    end
  end

  defp lease_expired?(_other), do: false

  # Marks the owning WorkflowRun's job entry Failed after its RunnerJob is
  # abandoned. Re-reads the WorkflowRun fresh on every attempt for the same
  # CAS-and-retry-against-fresh-state reason as the RunnerJob transition
  # above.
  defp fail_owning_job(_kube_conn, _run_ref, _job_key, 0), do: :ok

  defp fail_owning_job(kube_conn, run_ref, job_key, attempts_left) do
    with {:ok, run_object} <- kube_get(kube_conn, @workflow_run_gvk, @namespace, run_ref),
         {:ok, run_status} <- WorkflowRunStatus.from_wire(Map.get(run_object, "status", %{})) do
      failed_job_status = failed_job_status(Map.get(run_status.jobs, job_key))
      new_jobs = Map.put(run_status.jobs, job_key, failed_job_status)
      new_run_status = WorkflowRunStatus.update_jobs(run_status, new_jobs)
      resource_version = get_in(run_object, ["metadata", "resourceVersion"])

      case kube_patch_status(
             kube_conn,
             @workflow_run_gvk,
             @namespace,
             run_ref,
             WorkflowRunStatus.to_wire(new_run_status),
             resource_version
           ) do
        {:ok, _updated} ->
          :ok

        {:error, :conflict} ->
          fail_owning_job(kube_conn, run_ref, job_key, attempts_left - 1)

        {:error, reason} ->
          Logger.warning(
            "LeaseSweeper: failed to patch WorkflowRun #{run_ref} job #{job_key}: #{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, :not_found} ->
        # The owning WorkflowRun is gone — nothing left to mark.
        :ok

      {:error, reason} ->
        Logger.warning("LeaseSweeper: failed to read WorkflowRun #{run_ref}: #{inspect(reason)}")
        :ok
    end
  end

  defp failed_job_status(nil) do
    {:ok, job_status} = JobStatus.new(%{phase: :failed})
    job_status
  end

  defp failed_job_status(%JobStatus{} = current) do
    case JobStatus.update(current, %{phase: :failed}) do
      {:ok, updated} -> updated
      {:error, _reason} -> current
    end
  end

  defp kube_get({client_module, conn}, gvk, namespace, name),
    do: client_module.get(conn, gvk, namespace, name)

  defp kube_list({client_module, conn}, gvk, namespace, opts),
    do: client_module.list(conn, gvk, namespace, opts)

  defp kube_patch_status(
         {client_module, conn},
         gvk,
         namespace,
         name,
         status,
         expected_resource_version
       ),
       do:
         client_module.patch_status(conn, gvk, namespace, name, status, expected_resource_version)
end
