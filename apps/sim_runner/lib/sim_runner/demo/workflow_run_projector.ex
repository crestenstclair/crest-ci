defmodule SimRunner.Demo.WorkflowRunProjector do
  @moduledoc """
  Shared CAS-retry helper for patching a `WorkflowRun`'s `status`
  subresource.

  Both `SimRunner.Demo.ControllerInstance` (orchestration fields: queued /
  skipped jobs) and `SimRunner.Demo.GatewayWiring` (assignment fields:
  running / succeeded / failed) patch the SAME `WorkflowRunStatus` through
  this one retry loop, so both writers honor "status updates go through
  the status subresource with optimistic concurrency; a stale
  resourceVersion write is rejected and retried against fresh state, never
  forced" identically, rather than each re-implementing its own retry
  policy.
  """

  alias CrestCiContract.WorkflowRunStatus

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"
  @max_attempts 20

  @typedoc "`{adapter_module, adapter_conn}` — see `CrestCiContract.KubeClient`."
  @type kube_conn :: {module(), term()}

  @doc """
  Reads the current `WorkflowRunStatus` for `run_name`, applies
  `update_fun` to it, and patches the result back under optimistic
  concurrency. Retries on `{:error, :conflict}` against freshly re-read
  state (never forcing a stale write), bounded to a fixed attempt count —
  reconciliation is level-triggered, so a pass that gives up here is
  simply picked back up by the next pass.
  """
  @spec patch(kube_conn(), String.t(), (WorkflowRunStatus.t() -> WorkflowRunStatus.t())) ::
          :ok | {:error, term()}
  def patch(kube_conn, run_name, update_fun) do
    do_patch(kube_conn, run_name, update_fun, @max_attempts)
  end

  defp do_patch(_kube_conn, _run_name, _update_fun, 0), do: {:error, :cas_exhausted}

  defp do_patch({module, conn} = kube_conn, run_name, update_fun, attempts_left) do
    with {:ok, object} <- module.get(conn, @workflow_run_gvk, @namespace, run_name),
         {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(object, "status", %{})) do
      new_status = update_fun.(status)
      resource_version = get_in(object, ["metadata", "resourceVersion"])

      case module.patch_status(
             conn,
             @workflow_run_gvk,
             @namespace,
             run_name,
             WorkflowRunStatus.to_wire(new_status),
             resource_version
           ) do
        {:ok, _updated} ->
          :ok

        {:error, :conflict} ->
          do_patch(kube_conn, run_name, update_fun, attempts_left - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
