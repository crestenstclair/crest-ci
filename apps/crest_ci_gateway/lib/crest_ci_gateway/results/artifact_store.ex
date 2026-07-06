defmodule CrestCiGateway.Results.ArtifactStore do
  @moduledoc """
  Port: chunked artifact upload/finalize/read for job-produced artifacts.

  `port.Results.ArtifactStore` — an abstraction over "where artifact bytes
  and their finalized metadata live" so that
  `CrestCiGateway.Results.ArtifactsApi` (and any future application
  service) depends on this behaviour instead of a concrete storage
  technology. This slice ships `CrestCiGateway.Results.LocalFsArtifactStore`;
  a future S3-backed adapter slots in without touching any caller.

  Contract:

    * `create/5` begins an upload for artifact `name` within `(run, job)`,
      declaring its final size up front. Returns an opaque `upload_ref`
      threaded through `upload_part/4` and `finalize/3`.
    * `upload_part/4` is **idempotent by `(upload_ref, part_index)`** —
      resending the same part (e.g. after a runner reconnects to a
      different gateway replica) must never duplicate or corrupt the
      assembled content.
    * `finalize/3` is the **atomic commit point**: it verifies the
      assembled parts' total size and sha256 digest against
      `declared_digest`, and only a successful verification makes the
      artifact visible to `list/2` and `read/3`. A digest or size
      mismatch rejects the finalize and leaves nothing visible — there is
      no partially-visible state.
    * `list/2` returns only finalized artifacts for a run; an upload that
      was created but never (or unsuccessfully) finalized never appears.
    * `read/3` returns the full assembled bytes of a finalized artifact by
      `(run, name)`; reading an artifact that has not been finalized
      returns `{:error, :not_found}`, identically to one that was never
      created.

  `store` is an opaque struct identifying both the implementing module (via
  `@behaviour` dispatch on the struct's own module) and whatever
  configuration that module needs (e.g. a filesystem root). Callers never
  pattern-match on the struct's internals — they hold it opaquely and pass
  it back into this port's functions.

  `upload_ref` is likewise opaque to callers of this port: whatever token
  the implementing adapter needs to correlate `upload_part/4` and
  `finalize/3` calls with the upload begun by `create/5`. Callers pass it
  back verbatim and never inspect its shape.
  """

  alias CrestCiContract.JobKey
  alias CrestCiGateway.Results.ArtifactName
  alias CrestCiGateway.Results.ArtifactRecord

  @type store :: struct()
  @type run :: String.t()
  @type job :: JobKey.t()
  @type name :: ArtifactName.t()
  @type declared_size :: non_neg_integer()
  @type upload_ref :: term()
  @type part_index :: non_neg_integer()
  @type content :: binary()
  @type declared_digest :: String.t()

  @callback create(store, run, job, name, declared_size) ::
              {:ok, upload_ref} | {:error, :already_exists | term()}
  @callback upload_part(store, upload_ref, part_index, content) :: :ok | {:error, term()}
  @callback finalize(store, upload_ref, declared_digest) ::
              {:ok, ArtifactRecord.t()} | {:error, :digest_mismatch | :size_mismatch | term()}
  @callback list(store, run) :: {:ok, [ArtifactRecord.t()]}
  @callback read(store, run, name) :: {:ok, binary()} | {:error, :not_found}

  @doc """
  Begin an upload for artifact `name` within `(run, job)`, declaring its
  final size up front. Returns an opaque `upload_ref` to thread through
  `upload_part/4` and `finalize/3`. `{:error, :already_exists}` signals a
  deterministic-name collision with an existing upload or finalized
  artifact, mirroring the "409 AlreadyExists is a no-op" architectural
  invariant for replaying reconciles.

  Dispatches to whichever module the `store` struct belongs to — the
  caller depends on this port module, never on a concrete adapter.
  """
  @spec create(store, run, job, name, declared_size) ::
          {:ok, upload_ref} | {:error, :already_exists | term()}
  def create(%module{} = store, run, job, name, declared_size) do
    module.create(store, run, job, name, declared_size)
  end

  @doc """
  Upload one part of `upload_ref`'s content at `part_index`. Idempotent:
  resending an already-stored `(upload_ref, part_index)` pair changes
  nothing and still returns `:ok`.
  """
  @spec upload_part(store, upload_ref, part_index, content) :: :ok | {:error, term()}
  def upload_part(%module{} = store, upload_ref, part_index, content) do
    module.upload_part(store, upload_ref, part_index, content)
  end

  @doc """
  Finalize `upload_ref` as a servable artifact. Verifies the assembled
  parts' total size and sha256 digest against `declared_digest`; a
  mismatch rejects the finalize with `{:error, :digest_mismatch}` or
  `{:error, :size_mismatch}` and the artifact never becomes visible to
  `list/2` or `read/3`. Only a successful finalize is the atomic commit
  point that flips visibility.
  """
  @spec finalize(store, upload_ref, declared_digest) ::
          {:ok, ArtifactRecord.t()} | {:error, :digest_mismatch | :size_mismatch | term()}
  def finalize(%module{} = store, upload_ref, declared_digest) do
    module.finalize(store, upload_ref, declared_digest)
  end

  @doc """
  List finalized artifacts for `run`. Uploads that were created but never
  successfully finalized are never included.
  """
  @spec list(store, run) :: {:ok, [ArtifactRecord.t()]}
  def list(%module{} = store, run) do
    module.list(store, run)
  end

  @doc """
  Read the full assembled bytes of the finalized artifact `name` within
  `run`. Returns `{:error, :not_found}` for an artifact that was never
  created, never finalized, or does not exist under that name.
  """
  @spec read(store, run, name) :: {:ok, binary()} | {:error, :not_found}
  def read(%module{} = store, run, name) do
    module.read(store, run, name)
  end
end
