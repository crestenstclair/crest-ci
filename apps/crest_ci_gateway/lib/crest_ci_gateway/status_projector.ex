defmodule CrestCiGateway.StatusProjector do
  @moduledoc """
  `domainService.Gateway.StatusProjector` — projects runner-reported
  progress into a `WorkflowRun`'s `status.jobs.<jobKey>` record
  (`CrestCiContract.JobStatus`): Assigned/Running transitions,
  `outputs`, and completion results are all gateway-owned fields written
  through here.

  ## Dependency inversion

  `StatusProjector` depends only on the `CrestCiContract.KubeClient`
  port behaviour, never on a concrete adapter. Its `conn` argument is a
  `{client, adapter_conn}` pair: `client` is whatever module implements
  `CrestCiContract.KubeClient` (a `Req`-based real adapter, an in-memory
  test double, ...) and `adapter_conn` is that module's own opaque
  connection handle. Both halves are supplied by whatever composes a
  gateway replica (or a test) at boot/setup time — this module never
  hard-codes which adapter it talks to, so any `CrestCiContract.KubeClient`
  implementation is substitutable underneath it (LSP) with no change here.

  ## Status CAS with reread-and-retry

  `project/4` never forces a write: it patches the `status` subresource
  compare-and-swapped against the `resourceVersion` of the `workflow_run`
  it was handed. When `KubeClient.patch_status/6` reports `{:error,
  :conflict}` (another writer — the controller, or another active-active
  gateway replica — advanced the resourceVersion first), `StatusProjector`
  rereads the object fresh via `KubeClient.get/4`, reapplies `progress` on
  top of the current `jobs` map, and retries the patch. This continues,
  bounded by `@max_attempts`, until the patch succeeds or a
  non-conflict error is returned — the stale writer's value is never
  forced onto the store, matching the project's multi-writer status
  discipline.

  Applying `progress` on top of the current per-job status is delegated
  entirely to `CrestCiContract.JobStatus.new/1` (no existing record for
  `job_key` yet) or `CrestCiContract.JobStatus.update/2` (a record
  already exists) — in particular `update/2`'s `log_chunks` clamp to
  `max(current, incoming)` is inherited for free, so a stale `progress`
  resend can never regress `log_chunks` even when it arrives as part of
  a conflict-retry replay.

  This module keeps no process state of its own — every call is a pure
  function of its arguments plus whatever `KubeClient` reports, so a
  crashed-and-restarted caller (or a different gateway replica entirely)
  reconstructs nothing: there is nothing here to reconstruct.
  """

  alias CrestCiContract.JobKey
  alias CrestCiContract.JobStatus
  alias CrestCiContract.KubeClient
  alias CrestCiContract.WorkflowRunStatus

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}

  # Bounds the reread-and-retry loop so a pathologically hot write path
  # cannot spin forever; a lost race here surfaces as {:error, :conflict}
  # to the caller, which is free to retry the whole call again later.
  @max_attempts 5

  @typedoc """
  The concrete `CrestCiContract.KubeClient` implementation (`client`)
  paired with its own opaque connection handle (`adapter_conn`) — see
  the moduledoc's "Dependency inversion" section.
  """
  @type conn :: {module(), KubeClient.conn()}

  @typedoc "Field map accepted by `JobStatus.new/1` / `JobStatus.update/2` (atom keys, `phase` as an atom)."
  @type progress :: %{optional(atom()) => term()}

  @doc """
  Projects `progress` onto `job_key`'s `JobStatus` inside `workflow_run`,
  patching the `WorkflowRun`'s `status` subresource via `conn`.

  `workflow_run` is the Kubernetes wire object (as returned by
  `KubeClient.get/4` or `create/4`) the caller last observed; its
  `metadata.resourceVersion` is the optimistic-concurrency token used for
  the first patch attempt. On `{:error, :conflict}` this rereads the
  object fresh and retries — see the moduledoc.

  Returns `{:ok, object}` with the patched wire object once the status
  CAS succeeds, or `{:error, term}` for any non-conflict failure
  (including running out of retry attempts, surfaced as
  `{:error, :conflict}`).
  """
  @spec project(conn(), KubeClient.object(), JobKey.t(), progress()) ::
          {:ok, KubeClient.object()} | {:error, term()}
  def project({_client, _adapter_conn} = conn, %{} = workflow_run, job_key, progress)
      when is_binary(job_key) and is_map(progress) do
    attempt(conn, workflow_run, job_key, progress, @max_attempts)
  end

  @spec attempt(conn(), KubeClient.object(), JobKey.t(), progress(), non_neg_integer()) ::
          {:ok, KubeClient.object()} | {:error, term()}
  defp attempt(_conn, _workflow_run, _job_key, _progress, 0), do: {:error, :conflict}

  defp attempt({client, adapter_conn} = conn, workflow_run, job_key, progress, attempts_left) do
    name = get_in(workflow_run, ["metadata", "name"])
    namespace = get_in(workflow_run, ["metadata", "namespace"])
    resource_version = get_in(workflow_run, ["metadata", "resourceVersion"])

    with {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(workflow_run, "status", %{})),
         {:ok, updated_status} <- apply_progress(status, job_key, progress) do
      client.patch_status(
        adapter_conn,
        @workflow_run_gvk,
        namespace,
        name,
        WorkflowRunStatus.to_wire(updated_status),
        resource_version
      )
      |> handle_patch_result(conn, namespace, name, job_key, progress, attempts_left)
    end
  end

  @spec handle_patch_result(
          {:ok, KubeClient.object()} | {:error, term()},
          conn(),
          KubeClient.namespace(),
          KubeClient.name(),
          JobKey.t(),
          progress(),
          non_neg_integer()
        ) :: {:ok, KubeClient.object()} | {:error, term()}
  defp handle_patch_result({:ok, object}, _conn, _namespace, _name, _job_key, _progress, _left),
    do: {:ok, object}

  defp handle_patch_result(
         {:error, :conflict},
         {client, adapter_conn} = conn,
         namespace,
         name,
         job_key,
         progress,
         attempts_left
       ) do
    case client.get(adapter_conn, @workflow_run_gvk, namespace, name) do
      {:ok, fresh} -> attempt(conn, fresh, job_key, progress, attempts_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_patch_result(
         {:error, reason},
         _conn,
         _namespace,
         _name,
         _job_key,
         _progress,
         _left
       ),
       do: {:error, reason}

  @spec apply_progress(WorkflowRunStatus.t(), JobKey.t(), progress()) ::
          {:ok, WorkflowRunStatus.t()} | {:error, term()}
  defp apply_progress(%WorkflowRunStatus{jobs: jobs} = status, job_key, progress) do
    with {:ok, job_status} <- merge_job_status(Map.get(jobs, job_key), progress) do
      {:ok, WorkflowRunStatus.update_jobs(status, Map.put(jobs, job_key, job_status))}
    end
  end

  @spec merge_job_status(JobStatus.t() | nil, progress()) ::
          {:ok, JobStatus.t()} | {:error, term()}
  defp merge_job_status(nil, progress), do: JobStatus.new(progress)
  defp merge_job_status(%JobStatus{} = current, progress), do: JobStatus.update(current, progress)
end
