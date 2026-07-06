defmodule CrestCiGateway.BlobStore do
  @moduledoc """
  Port: chunked log storage for job step output.

  `port.Gateway.BlobStore` — an abstraction over "where log chunks live" so
  that `CrestCiGateway.LogIngest` (and any future application service) can
  depend on this behaviour instead of a concrete storage technology. This
  slice ships `CrestCiGateway.LocalFsBlobStore`; a future S3-backed adapter
  slots in without touching any caller.

  Contract:

    * `append_chunk/6` is idempotent by `(run, job, step, seq)` — appending
      the same chunk key twice (concurrently or sequentially) never
      duplicates stored content. Implementations must write-if-absent.
    * `read_log/3` returns the full log for a job in strict ascending
      chunk-seq order, regardless of the order chunks arrived in.

  `store` is an opaque struct identifying both the implementing module (via
  `@behaviour` dispatch on the struct's own module) and whatever
  configuration that module needs (e.g. a filesystem root). Callers never
  pattern-match on the struct's internals — they hold it opaquely and pass
  it back into this port's functions.
  """

  @type store :: struct()
  @type run :: String.t()
  @type job :: String.t()
  @type step :: String.t()
  @type seq :: non_neg_integer()
  @type content :: binary()

  @callback append_chunk(store, run, job, step, seq, content) :: :ok | {:error, term()}
  @callback read_log(store, run, job) :: {:ok, binary()} | {:error, term()}

  @doc """
  Append one log chunk, keyed by `(run, job, step, seq)`. Idempotent:
  resending an already-stored chunk changes nothing and still returns `:ok`.

  Dispatches to whichever module the `store` struct belongs to — the caller
  depends on this port module, never on a concrete adapter.
  """
  @spec append_chunk(store, run, job, step, seq, content) :: :ok | {:error, term()}
  def append_chunk(%module{} = store, run, job, step, seq, content) do
    module.append_chunk(store, run, job, step, seq, content)
  end

  @doc """
  Read the full, ordered log text for a job: every chunk across every step,
  concatenated in ascending `(step, seq)` order.
  """
  @spec read_log(store, run, job) :: {:ok, binary()} | {:error, term()}
  def read_log(%module{} = store, run, job) do
    module.read_log(store, run, job)
  end
end
