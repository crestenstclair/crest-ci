defmodule CrestCiGateway.Results.LogCompactor do
  @moduledoc """
  Domain Service: `domainService.Results.LogCompactor` — pure planning +
  idempotent execution turning a job's ingested `CrestCiGateway.LogChunk`s
  into a single durable compacted log blob, described by a
  `CrestCiGateway.LogArchive`.

  ## Planning (pure)

  `plan/2` takes the chunks known to have been ingested for a job and
  produces the ordered, deduplicated archive content: every `(step, seq)`
  appears exactly once — first-write-wins, matching
  `port.Gateway.BlobStore.append_chunk/6`'s idempotency contract — ordered
  by `step` and then by `seq` ascending within each step, the same order
  `BlobStore.read_log/3` guarantees. This half of the module is a pure
  function: no I/O, no process state, safe to call any number of times
  with the same input for the same result.

  ## Execution (idempotent)

  `compact/4` uses the plan to write the compacted content as a single
  blob at a deterministic archive location (`archive_ref/1`, a `BlobStore`
  `job` identifier distinct from — never nested inside — the job's own
  live-chunk directory) via `BlobStore.append_chunk/6`. Because
  `append_chunk/6` is write-if-absent, calling `compact/4` again for the
  same job before its `LogArchive` is recorded never rewrites, duplicates,
  or corrupts the archived bytes.

  ## No-op on an already-archived job

  Callers (e.g. `applicationService.Results.ArchiveOnComplete`) hold the
  job's current `LogArchive`, if any, in its status. Passing that existing
  archive in as `existing_archive` short-circuits `compact/4` to a pure
  no-op — `{:ok, existing_archive, []}` — touching neither the plan nor
  the store, so re-running compaction after a crash or a duplicate
  reconcile is always safe: "compacting an already-archived job is a
  no-op". The deletion list is empty in that case because there is
  nothing new to delete — a prior compaction already claimed this job's
  live chunks.
  """

  alias CrestCiContract.JobKey
  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LogArchive
  alias CrestCiGateway.LogChunk

  @archive_step "log"
  @archive_seq 0

  defmodule Deps do
    @moduledoc """
    Collaborators `LogCompactor.compact/4` needs, supplied by whichever
    assembler wires a gateway replica together at boot: `blob_store` is an
    opaque `port.Gateway.BlobStore` store term — `LogCompactor` calls it
    only through the `CrestCiGateway.BlobStore` port module, never through
    a hard-coded adapter — and `run` is the run identifier the job being
    compacted belongs to.
    """

    @enforce_keys [:blob_store, :run]
    defstruct [:blob_store, :run]

    @type t :: %__MODULE__{
            blob_store: BlobStore.store(),
            run: BlobStore.run()
          }
  end

  @doc """
  Pure planning step: orders and deduplicates `chunks` belonging to
  `job_key` into the archive's content.

  Chunks belonging to a different job (passed in by caller mistake) are
  filtered out rather than raising. The remainder is deduplicated by
  `LogChunk.key/1`, keeping the FIRST occurrence per `(step, seq)` — this
  matches `BlobStore.append_chunk/6`'s write-if-absent contract, where the
  first stored write for a key always wins over any later resend — and
  sorted by `step` then by `seq` ascending within each step, the same
  order `BlobStore.read_log/3` guarantees regardless of upload arrival
  order.

  Returns the ordered, deduplicated chunk list — also the deletion list of
  every live chunk now durably represented in the archive content —
  alongside the concatenated archive content itself.
  """
  @spec plan(JobKey.t(), [LogChunk.t()]) :: {[LogChunk.t()], binary()}
  def plan(job_key, chunks) when is_binary(job_key) and is_list(chunks) do
    ordered =
      chunks
      |> Enum.filter(&(&1.job_key == job_key))
      |> Enum.uniq_by(&LogChunk.key/1)
      |> Enum.sort_by(&{&1.step, &1.seq})

    content = ordered |> Enum.map(& &1.content) |> IO.iodata_to_binary()

    {ordered, content}
  end

  @doc """
  Compact `job_key`'s ingested `chunks` into a durable `LogArchive`.

  If `existing_archive` is non-`nil`, this is a pure no-op — the job was
  already archived — returning `{:ok, existing_archive, []}` without
  touching the plan or the store.

  Otherwise `chunks` are planned via `plan/2`, the resulting content is
  written to `deps.blob_store` at `archive_ref(job_key)` (idempotent by
  the store's own write-if-absent contract), and a fresh `LogArchive` is
  returned alongside the ordered chunk list (the deletion list of every
  live chunk the caller may now safely remove).

  Rejects a malformed `job_key` (per `CrestCiContract.JobKey.new/1`) or a
  malformed combination of `existing_archive`/`chunks` with a tagged
  error, never raising.
  """
  @spec compact(Deps.t(), JobKey.t(), LogArchive.t() | nil, [LogChunk.t()]) ::
          {:ok, LogArchive.t(), [LogChunk.t()]} | {:error, term()}
  def compact(%Deps{}, job_key, %LogArchive{} = existing_archive, _chunks)
      when is_binary(job_key) do
    {:ok, existing_archive, []}
  end

  def compact(%Deps{} = deps, job_key, nil, chunks) when is_list(chunks) do
    with {:ok, valid_job_key} <- JobKey.new(job_key) do
      {ordered, content} = plan(valid_job_key, chunks)
      ref = archive_ref(valid_job_key)

      with :ok <-
             BlobStore.append_chunk(
               deps.blob_store,
               deps.run,
               ref,
               @archive_step,
               @archive_seq,
               content
             ),
           {:ok, archive} <-
             LogArchive.new(valid_job_key, ref, byte_size(content), count_lines(content)) do
        {:ok, archive, ordered}
      end
    end
  end

  def compact(%Deps{}, _job_key, _existing_archive, _chunks),
    do: {:error, :invalid_compaction_request}

  @doc """
  The deterministic archive location a job's compacted log is written
  under — a `BlobStore` `job` identifier distinct from (and never nested
  inside) the job's own live-chunk directory, so archiving never disturbs
  and is never disturbed by in-flight chunk uploads for the same job.
  Also used as the resulting `LogArchive.run_ref`.

  Pure and deterministic: the same `job_key` always yields the same
  reference, across processes and across restarts.
  """
  @spec archive_ref(JobKey.t()) :: String.t()
  def archive_ref(job_key) when is_binary(job_key), do: "archives/" <> job_key

  # -- internal ------------------------------------------------------------

  # Number of lines in `content`: the count of newline-terminated lines
  # plus one more if the final line has content but no trailing newline.
  # An empty binary has zero lines.
  defp count_lines(""), do: 0

  defp count_lines(content) when is_binary(content) do
    newline_count = content |> :binary.matches("\n") |> length()

    if String.ends_with?(content, "\n") do
      newline_count
    else
      newline_count + 1
    end
  end
end
