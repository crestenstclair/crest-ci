defmodule CrestCiGateway.LogIngest do
  @moduledoc """
  `applicationService.Gateway.LogIngest` — accepts runner-uploaded
  `CrestCiGateway.LogChunk`s and appends them to the job's log via
  `port.Gateway.BlobStore`.

  Ingestion is idempotent by `(job_key, step, seq)`: this module does not
  keep its own record of which chunks it has already seen. Instead it
  delegates entirely to `BlobStore.append_chunk/6`'s write-if-absent
  contract, which is idempotent by `(run, job, step, seq)`. Resending an
  already-ingested chunk — even with different content, as can happen
  when a runner retries an upload across a gateway replica failover —
  changes nothing: the first write for that key wins.

  This keeps `LogIngest` free of the mutable shared state the project's
  architectural invariants forbid: there is no ETS table, no `Agent`, no
  in-process counter that two gateway replicas would need to agree on.
  "Have we already stored this chunk?" is answered by the `BlobStore`
  itself (a single shared store, or storage all replicas see alike), not
  by anything living in this process's memory — so a killed-and-restarted
  replica converges immediately, and any other active-active replica
  ingesting the same chunk concurrently gets the identical idempotent
  outcome.

  Dependency Inversion: `LogIngest` depends on the `BlobStore` port
  (`CrestCiGateway.BlobStore`) via an injected `Deps` struct, never on a
  concrete adapter module — `CrestCiGateway.LocalFsBlobStore` or any
  future adapter is interchangeable underneath it without any change
  here.
  """

  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LogChunk

  defmodule Deps do
    @moduledoc """
    Collaborators `LogIngest.ingest_chunk/5` needs, supplied by whichever
    assembler wires a gateway replica together at boot. `blob_store` is an
    opaque `port.Gateway.BlobStore` store term — `LogIngest` calls it only
    through the `CrestCiGateway.BlobStore` port module, never through a
    hard-coded adapter — and `run` is the run identifier every ingested
    job's chunks are filed under.
    """

    @enforce_keys [:blob_store, :run]
    defstruct [:blob_store, :run]

    @type t :: %__MODULE__{
            blob_store: BlobStore.store(),
            run: BlobStore.run()
          }
  end

  @doc """
  Ingest one log chunk uploaded for `job_key`/`step`/`seq`.

  Validates the chunk's shape via `LogChunk.new/4` first — a malformed
  chunk (bad job key, empty step, negative seq, non-binary content) is
  rejected with `{:error, :invalid_log_chunk}` before any store access is
  attempted. A well-shaped chunk is appended to `deps.blob_store` under
  `deps.run`; the append is idempotent by `(run, job_key, step, seq)`, so
  calling this repeatedly with the same key is always safe and never
  duplicates stored content.
  """
  @spec ingest_chunk(Deps.t(), String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def ingest_chunk(%Deps{} = deps, job_key, step, seq, content) do
    with {:ok, chunk} <- LogChunk.new(job_key, step, seq, content) do
      BlobStore.append_chunk(
        deps.blob_store,
        deps.run,
        chunk.job_key,
        chunk.step,
        chunk.seq,
        chunk.content
      )
    end
  end
end
