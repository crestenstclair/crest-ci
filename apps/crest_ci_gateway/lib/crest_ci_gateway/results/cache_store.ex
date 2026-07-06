defmodule CrestCiGateway.Results.CacheStore do
  @moduledoc """
  Port: cache blob storage with GitHub-compatible restore-key and scope
  semantics.

  `port.Results.CacheStore` — an abstraction over "where committed cache
  blobs live and how their metadata is indexed" so that
  `CrestCiGateway.Results.CacheApi` (and any future application service)
  depends on this behaviour instead of a concrete storage technology. This
  slice ships `CrestCiGateway.Results.LocalFsCacheStore`; a future
  S3-backed adapter slots in without touching any caller.

  Contract:

    * `reserve/4` opens a reservation for `(key, version, scope)`. A key
      that already has a *Committed* entry is immutable — re-reserving it
      returns `{:error, :already_committed}` rather than clobbering the
      existing blob. Concurrent reservations of the same not-yet-committed
      key are the implementing adapter's concern; this port only names the
      operation.
    * `upload/4` appends content to a reservation at a given byte
      `offset`, **idempotent by `(reservation, offset)`** — resending the
      same offset (e.g. after a runner reconnects to a different gateway
      replica) must never duplicate or corrupt the assembled blob.
    * `commit/3` is the atomic finalize step: it verifies the assembled
      bytes match `declared_size` and only then makes the entry
      *Committed* (and therefore servable via `lookup/4`). A size mismatch
      rejects the commit and leaves nothing servable under that key.
    * `lookup/4` never chooses its own match — it **delegates match
      choice to `CrestCiGateway.Results.RestoreKeyResolver`**, a pure
      domain service that implements GitHub's exact-key-then-longest-
      prefix-most-recent semantics scoped by `scope_chain`. A successful
      lookup touches the winning entry's `lastUsedAt` (adapter concern) and
      returns its bytes; no match is a soft `:miss`, never an error.
    * `evict/2` never chooses eviction order itself — it **delegates the
      choice to `CrestCiGateway.Results.LruEvictor`**, a pure domain
      service that picks the oldest-`lastUsedAt`-first set of *Committed*
      entries needed to respect `byte_budget`. *Reserved* entries are never
      eviction candidates.

  `store` is an opaque struct identifying both the implementing module (via
  `@behaviour` dispatch on the struct's own module) and whatever
  configuration that module needs (e.g. a filesystem root). Callers never
  pattern-match on the struct's internals — they hold it opaquely and pass
  it back into this port's functions.

  `reservation` and `entry` are likewise opaque to callers of this port:
  a `reservation` is whatever token the implementing adapter needs to
  correlate `upload/4` and `commit/3` calls with the reserved key, and an
  `entry` is the adapter's `CrestCiGateway.Results.CacheEntry`-shaped
  metadata record. Callers pass reservations back verbatim and read
  entries through their own accessors — this port does not constrain
  their internal shape beyond "a struct".
  """

  alias CrestCiGateway.Results.CacheScope

  @type store :: struct()
  @type key :: String.t()
  @type version :: String.t()
  @type scope :: CacheScope.t()
  @type reservation :: term()
  @type entry :: struct()
  @type offset :: non_neg_integer()
  @type content :: binary()
  @type declared_size :: non_neg_integer()
  @type restore_keys :: [String.t()]
  @type scope_chain :: [scope]
  @type byte_budget :: non_neg_integer()

  @callback reserve(store, key, version, scope) ::
              {:ok, reservation} | {:error, :already_committed}
  @callback upload(store, reservation, offset, content) :: :ok
  @callback commit(store, reservation, declared_size) ::
              {:ok, entry} | {:error, :size_mismatch}
  @callback lookup(store, key, restore_keys, scope_chain) ::
              {:ok, entry, binary()} | :miss
  @callback evict(store, byte_budget) :: {:ok, [entry]}

  @doc """
  Reserve `key` at `version` within `scope`. Rejects with
  `{:error, :already_committed}` when `key` already names a Committed
  entry — a committed cache blob is immutable, never silently replaced.

  Dispatches to whichever module the `store` struct belongs to — the
  caller depends on this port module, never on a concrete adapter.
  """
  @spec reserve(store, key, version, scope) :: {:ok, reservation} | {:error, :already_committed}
  def reserve(%module{} = store, key, version, scope) do
    module.reserve(store, key, version, scope)
  end

  @doc """
  Append `content` to `reservation` at `offset`. Idempotent: resending an
  already-written `(reservation, offset)` pair changes nothing and still
  returns `:ok`.
  """
  @spec upload(store, reservation, offset, content) :: :ok
  def upload(%module{} = store, reservation, offset, content) do
    module.upload(store, reservation, offset, content)
  end

  @doc """
  Finalize `reservation` as a Committed cache entry. Verifies the
  assembled content's size against `declared_size`; a mismatch rejects
  the commit with `{:error, :size_mismatch}` and the entry never becomes
  servable via `lookup/4`.
  """
  @spec commit(store, reservation, declared_size) :: {:ok, entry} | {:error, :size_mismatch}
  def commit(%module{} = store, reservation, declared_size) do
    module.commit(store, reservation, declared_size)
  end

  @doc """
  Look up the cache entry to serve for `key`, falling back through
  `restore_keys` (longest-prefix, most-recent) when `key` itself misses,
  restricted to entries visible under `scope_chain`. Match selection is
  delegated to `CrestCiGateway.Results.RestoreKeyResolver`; a hit touches
  the winning entry's `lastUsedAt`. Returns `:miss` — never an error —
  when nothing matches.
  """
  @spec lookup(store, key, restore_keys, scope_chain) :: {:ok, entry, binary()} | :miss
  def lookup(%module{} = store, key, restore_keys, scope_chain) do
    module.lookup(store, key, restore_keys, scope_chain)
  end

  @doc """
  Evict entries until total stored size respects `byte_budget`. Eviction
  order is delegated to `CrestCiGateway.Results.LruEvictor` (oldest
  `lastUsedAt` first); Reserved entries are never evicted.
  """
  @spec evict(store, byte_budget) :: {:ok, [entry]}
  def evict(%module{} = store, byte_budget) do
    module.evict(store, byte_budget)
  end
end
