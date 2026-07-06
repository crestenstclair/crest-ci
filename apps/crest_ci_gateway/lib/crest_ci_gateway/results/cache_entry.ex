defmodule CrestCiGateway.Results.CacheEntry do
  @moduledoc """
  Value Object: `valueObject.Results.CacheEntry` — one stored cache blob's
  metadata.

  A `CacheEntry` is pure data: no process state, no I/O. It describes a
  single cache blob addressed by `key` within a `scope`, and its lifecycle
  phase. Only `:committed` entries are servable to runners — a `:reserved`
  entry marks a cache upload in flight (a runner has claimed the slot but
  has not finished uploading) and must never be handed out as a cache hit,
  because its blob bytes may not exist yet or may be incomplete.

  Fields:
    * `key` — the cache key (`CacheKey`), a plain string identifying the
      blob's logical contents within its scope
    * `scope` — the cache scope (`CacheScope`), a plain string
      partitioning cache entries (e.g. by repository/branch) so a lookup
      in one scope never returns another scope's blob
    * `size_bytes` — the blob's size in bytes
    * `state` — `:reserved` (upload in flight, not servable) or
      `:committed` (upload complete, servable)
    * `version` — an opaque version string; distinguishes entries created
      for the same `(scope, key)` across reservation/eviction cycles
    * `created_at` — ISO 8601 timestamp string, when the entry was
      reserved
    * `last_used_at` — ISO 8601 timestamp string, updated on cache hits;
      used by eviction to find cold entries

  `CacheKey` and `CacheScope` are plain string value objects (no wrapping
  struct), following the same convention as `CrestCiContract.JobKey` —
  both Kubernetes object names and the JSON wire shape want a bare string.

  This module holds no authoritative state itself: a `CacheEntry` is only
  ever a projection of a Kubernetes custom resource's spec/status. Nothing
  here survives a crash except by being reconstructed from that resource.
  """

  @enforce_keys [
    :key,
    :scope,
    :size_bytes,
    :state,
    :version,
    :created_at,
    :last_used_at
  ]
  defstruct [
    :key,
    :scope,
    :size_bytes,
    :state,
    :version,
    :created_at,
    :last_used_at
  ]

  @type cache_key :: String.t()
  @type cache_scope :: String.t()
  @type state :: :reserved | :committed

  @type t :: %__MODULE__{
          key: cache_key(),
          scope: cache_scope(),
          size_bytes: non_neg_integer(),
          state: state(),
          version: String.t(),
          created_at: String.t(),
          last_used_at: String.t()
        }

  @states [:reserved, :committed]

  @doc """
  Builds a `CacheEntry` from field values, validating basic shape: `key`
  and `scope` non-empty binaries, `size_bytes` a non-negative integer,
  `state` one of `:reserved` or `:committed`, `version` a non-empty
  binary, and `created_at` / `last_used_at` non-empty binaries (ISO 8601
  timestamp strings — parsing/formatting is the caller's concern, this
  module only checks shape). Returns `{:error, :invalid_cache_entry}` for
  anything else rather than raising.
  """
  @spec new(
          cache_key(),
          cache_scope(),
          non_neg_integer(),
          state(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, t()} | {:error, :invalid_cache_entry}
  def new(key, scope, size_bytes, state, version, created_at, last_used_at)
      when is_binary(key) and byte_size(key) > 0 and
             is_binary(scope) and byte_size(scope) > 0 and
             is_integer(size_bytes) and size_bytes >= 0 and
             state in @states and
             is_binary(version) and byte_size(version) > 0 and
             is_binary(created_at) and byte_size(created_at) > 0 and
             is_binary(last_used_at) and byte_size(last_used_at) > 0 do
    {:ok,
     %__MODULE__{
       key: key,
       scope: scope,
       size_bytes: size_bytes,
       state: state,
       version: version,
       created_at: created_at,
       last_used_at: last_used_at
     }}
  end

  def new(_key, _scope, _size_bytes, _state, _version, _created_at, _last_used_at),
    do: {:error, :invalid_cache_entry}

  @doc """
  The `(scope, key)` lookup identity this entry is addressed by. Two
  entries with equal identity are candidates for the same logical cache
  slot — `version` (not identity) is what distinguishes successive
  reservations of that slot.
  """
  @spec identity(t()) :: {cache_scope(), cache_key()}
  def identity(%__MODULE__{scope: scope, key: key}), do: {scope, key}

  @doc """
  Whether this entry is servable as a cache hit. Only `:committed`
  entries are servable — a `:reserved` entry's upload may still be in
  flight or may never complete, so it must never be handed out.
  """
  @spec servable?(t()) :: boolean()
  def servable?(%__MODULE__{state: :committed}), do: true
  def servable?(%__MODULE__{state: :reserved}), do: false

  @doc """
  Transitions a `:reserved` entry to `:committed`, marking its upload
  complete and servable. Returns `{:error, :not_reserved}` if the entry
  is already `:committed` — commit is a one-way, one-time transition, not
  idempotent re-application (the entry's `version` identifies which
  reservation is being committed; committing twice would silently accept
  a second, possibly different, upload under the same identity).
  """
  @spec commit(t()) :: {:ok, t()} | {:error, :not_reserved}
  def commit(%__MODULE__{state: :reserved} = entry),
    do: {:ok, %__MODULE__{entry | state: :committed}}

  def commit(%__MODULE__{state: :committed}), do: {:error, :not_reserved}

  @doc """
  Returns a copy of the entry with `last_used_at` updated to `timestamp`.
  Called on cache hits so eviction can find cold entries; does not touch
  any other field, in particular never `state` — touching a `:reserved`
  entry does not make it servable.
  """
  @spec touch(t(), String.t()) :: t()
  def touch(%__MODULE__{} = entry, timestamp)
      when is_binary(timestamp) and byte_size(timestamp) > 0 do
    %__MODULE__{entry | last_used_at: timestamp}
  end

  @doc """
  Renders a `CacheEntry` to the Kubernetes/HTTP JSON wire map (camelCase
  keys), suitable for `Jason.encode!/1`. `state` is rendered as its
  capitalized wire form (`"Reserved"` / `"Committed"`) per the resource
  declaration's enum.
  """
  @spec to_wire(t()) :: %{String.t() => String.t() | non_neg_integer()}
  def to_wire(%__MODULE__{} = entry) do
    %{
      "key" => entry.key,
      "scope" => entry.scope,
      "sizeBytes" => entry.size_bytes,
      "state" => state_to_wire(entry.state),
      "version" => entry.version,
      "createdAt" => entry.created_at,
      "lastUsedAt" => entry.last_used_at
    }
  end

  @doc """
  Parses a JSON wire map (string-keyed, camelCase, as produced by
  `Jason.decode!/1`) into a `CacheEntry`. Rejects maps missing any
  required field, with a field of the wrong type, or with a `state`
  outside `"Reserved"` / `"Committed"`, returning
  `{:error, :invalid_cache_entry}` rather than raising.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_cache_entry}
  def from_wire(%{} = wire) do
    with {:ok, key} <- fetch_string(wire, "key"),
         {:ok, scope} <- fetch_string(wire, "scope"),
         {:ok, size_bytes} <- fetch_non_neg_integer(wire, "sizeBytes"),
         {:ok, state} <- fetch_state(wire, "state"),
         {:ok, version} <- fetch_string(wire, "version"),
         {:ok, created_at} <- fetch_string(wire, "createdAt"),
         {:ok, last_used_at} <- fetch_string(wire, "lastUsedAt") do
      new(key, scope, size_bytes, state, version, created_at, last_used_at)
    else
      :error -> {:error, :invalid_cache_entry}
    end
  end

  def from_wire(_other), do: {:error, :invalid_cache_entry}

  @wire_string_keys ~w(key scope version createdAt lastUsedAt)

  defp fetch_string(wire, key) when key in @wire_string_keys do
    case Map.get(wire, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_non_neg_integer(wire, "sizeBytes") do
    case Map.get(wire, "sizeBytes") do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_state(wire, "state") do
    case Map.get(wire, "state") do
      "Reserved" -> {:ok, :reserved}
      "Committed" -> {:ok, :committed}
      _other -> :error
    end
  end

  defp state_to_wire(:reserved), do: "Reserved"
  defp state_to_wire(:committed), do: "Committed"
end
