defmodule CrestCiGateway.Results.ArchiveOnComplete do
  @moduledoc """
  `applicationService.Results.ArchiveOnComplete` — the gateway's job
  completion hook: compacts a completed job's live log chunks into a
  single durable `CrestCiGateway.LogArchive` and records the archive
  pointer onto the job's status, then deletes the job's now-redundant
  live chunks.

  ## Orchestration, not policy

  All planning/dedup/ordering logic belongs to
  `domainService.Results.LogCompactor` (`LogCompactor.compact/4`); this
  module only wires it to its two collaborators: `port.Gateway.BlobStore`
  (where live chunks and the archive blob live) and
  `domainService.Gateway.StatusProjector` (how the archive pointer gets
  written onto the `WorkflowRun`'s `status` subresource under the
  project's CAS discipline). Neither collaborator is instantiated here —
  both are opaque abstractions supplied via `Deps`, so any adapter
  (`CrestCiGateway.LocalFsBlobStore`, a real `CrestCiContract.KubeClient`
  adapter, or a test double) is substitutable underneath this module
  without any change here (DIP).

  ## Idempotent, safe to re-run

  `archive/3` never trusts the `workflow_run` object handed to it by the
  caller as the source of truth for "has this job already been archived"
  — it always rereads the object fresh via the injected `kube_conn`
  first. This matters because a caller (a controller reconcile loop, a
  gateway replica retry, or — as in this asset's proof — a test calling
  `archive/3` twice against the same stale `workflow_run` capture) cannot
  be relied on to have observed the effect of a prior call; only the
  resource store itself is authoritative (matches this project's
  level-triggered, re-derivable-after-restart discipline).

  If the freshly-read status already carries a recorded archive pointer
  for `job_key`, `archive/3` is a pure no-op: it returns that same
  archive without touching `BlobStore` or `StatusProjector` again —
  `LogCompactor.compact/4`'s own "compacting an already-archived job is a
  no-op" contract is what makes this safe, this module just needs to
  supply the existing archive so `compact/4` can take that short-circuit.

  Otherwise, the job's live chunks are read via `BlobStore.list_chunks/3`,
  compacted (`LogCompactor.compact/4`), the resulting `LogArchive`
  recorded onto the job's status `outputs` map (a JSON-encoded pointer,
  merged into whatever `outputs` the job's status already carries —
  never clobbering fields other writers may have set) via
  `StatusProjector.project/4` (status-subresource CAS, reread-and-retry
  under the hood), and finally the job's live chunks are deleted via
  `BlobStore.delete_job/3`. A crash between any of these steps is safe:
  the next call rereads fresh state and either finds the archive already
  recorded (no-op) or repeats the whole sequence from scratch — nothing
  here depends on this process's memory surviving.
  """

  alias CrestCiContract.WorkflowRunStatus
  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LogArchive
  alias CrestCiGateway.LogChunk
  alias CrestCiGateway.Results.LogCompactor
  alias CrestCiGateway.StatusProjector

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}

  # Reserved key under a job's status `outputs` map holding the
  # JSON-encoded `LogArchive.to_wire/1` pointer, once recorded.
  @archive_output_key "logArchive"

  defmodule Deps do
    @moduledoc """
    Collaborators `ArchiveOnComplete.archive/3` needs, supplied by
    whichever assembler wires a gateway replica together at boot:
    `blob_store` is an opaque `port.Gateway.BlobStore` store term (never a
    hard-coded adapter), `run` is the run identifier the job being
    archived belongs to, and `kube_conn` is the
    `CrestCiGateway.StatusProjector.conn/0`-shaped `{client, adapter_conn}`
    pair used both to reread the `WorkflowRun` fresh and to project the
    recorded archive pointer through `StatusProjector`.
    """

    @enforce_keys [:blob_store, :run, :kube_conn]
    defstruct [:blob_store, :run, :kube_conn]

    @type t :: %__MODULE__{
            blob_store: BlobStore.store(),
            run: BlobStore.run(),
            kube_conn: StatusProjector.conn()
          }
  end

  @doc """
  Archive `job_key`'s live log chunks, recording the resulting
  `LogArchive` onto `workflow_run`'s status and deleting the job's live
  chunks once archived.

  `workflow_run` need only carry enough to locate the object
  (`metadata.name`/`metadata.namespace`) — its `status` is never trusted
  as-is; the object is always reread fresh via `deps.kube_conn` first, so
  passing a stale capture (as a retried caller may) is safe.

  Idempotent: calling this again for a job whose status already carries a
  recorded archive pointer is a pure no-op that returns the same
  `LogArchive`, touching neither `BlobStore` nor the status subresource
  again.
  """
  @spec archive(Deps.t(), map(), String.t()) :: {:ok, LogArchive.t()} | {:error, term()}
  def archive(%Deps{} = deps, %{} = workflow_run, job_key) when is_binary(job_key) do
    name = get_in(workflow_run, ["metadata", "name"])
    namespace = get_in(workflow_run, ["metadata", "namespace"])
    {client, adapter_conn} = deps.kube_conn

    with {:ok, fresh_workflow_run} <-
           client.get(adapter_conn, @workflow_run_gvk, namespace, name),
         {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(fresh_workflow_run, "status", %{})),
         {existing_archive, outputs} <- existing_archive_and_outputs(status, job_key),
         {:ok, raw_chunks} <- BlobStore.list_chunks(deps.blob_store, deps.run, job_key),
         {:ok, chunks} <- build_chunks(job_key, raw_chunks) do
      compactor_deps = %LogCompactor.Deps{blob_store: deps.blob_store, run: deps.run}

      with {:ok, archive, _ordered} <-
             LogCompactor.compact(compactor_deps, job_key, existing_archive, chunks) do
        finalize(deps, fresh_workflow_run, job_key, existing_archive, archive, outputs)
      end
    end
  end

  # -- internal --------------------------------------------------------

  @spec existing_archive_and_outputs(WorkflowRunStatus.t(), String.t()) ::
          {LogArchive.t() | nil, %{optional(String.t()) => String.t()}}
  defp existing_archive_and_outputs(%WorkflowRunStatus{jobs: jobs}, job_key) do
    case Map.get(jobs, job_key) do
      nil ->
        {nil, %{}}

      job_status ->
        outputs = job_status.outputs || %{}
        {decode_archive(outputs), outputs}
    end
  end

  @spec decode_archive(%{optional(String.t()) => String.t()}) :: LogArchive.t() | nil
  defp decode_archive(outputs) do
    with wire when is_binary(wire) <- Map.get(outputs, @archive_output_key),
         {:ok, decoded} <- Jason.decode(wire),
         {:ok, archive} <- LogArchive.from_wire(decoded) do
      archive
    else
      _other -> nil
    end
  end

  @spec build_chunks(String.t(), [{String.t(), non_neg_integer(), binary()}]) ::
          {:ok, [LogChunk.t()]} | {:error, term()}
  defp build_chunks(job_key, raw_chunks) do
    raw_chunks
    |> Enum.reduce_while({:ok, []}, fn {step, seq, content}, {:ok, acc} ->
      case LogChunk.new(job_key, step, seq, content) do
        {:ok, chunk} -> {:cont, {:ok, [chunk | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Already archived (per the freshly-reread status): a pure no-op —
  # LogCompactor.compact/4 already short-circuited to the existing
  # archive above, so there is nothing new to record or delete.
  @spec finalize(
          Deps.t(),
          map(),
          String.t(),
          LogArchive.t() | nil,
          LogArchive.t(),
          %{optional(String.t()) => String.t()}
        ) :: {:ok, LogArchive.t()} | {:error, term()}
  defp finalize(_deps, _workflow_run, _job_key, %LogArchive{}, archive, _outputs) do
    {:ok, archive}
  end

  # First time this job is archived: record the archive pointer (merged
  # into whatever outputs already exist, never clobbering other writers'
  # keys) via StatusProjector, then delete the job's live chunks.
  defp finalize(deps, workflow_run, job_key, nil, archive, outputs) do
    merged_outputs =
      Map.put(outputs, @archive_output_key, Jason.encode!(LogArchive.to_wire(archive)))

    with {:ok, _object} <-
           StatusProjector.project(deps.kube_conn, workflow_run, job_key, %{
             outputs: merged_outputs
           }),
         :ok <- BlobStore.delete_job(deps.blob_store, deps.run, job_key) do
      {:ok, archive}
    end
  end
end
