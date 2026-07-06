defmodule CrestCiGateway.Results.CacheScope do
  @moduledoc """
  `CacheScope` — the visibility scope a cache entry is stored and looked
  up under.

  A plain value object: no process state, no I/O. It answers "which
  cache entries can this lookup see?" for a given `(repo, ref)` pair.

  Fields:
    * `repo` — the repository the cache belongs to
    * `ref` — the git ref (branch/tag) the cache was written from or is
      being looked up for

  Cache lookup is scoped for isolation (a feature branch must not see
  another feature branch's cache) but falls back for reuse: a lookup
  against `ref` that misses walks to the repo's default branch ref next,
  so a fresh branch still gets a warm cache seeded by the last build on
  the default branch. `lookup_chain/2` encodes that walk order; nothing
  in this module performs the actual store lookup — this is data plus
  the scope-derivation rule, kept pure and testable in isolation from
  `CrestCiGateway.BlobStore`.

  Identity: two scopes are the same scope iff `repo` and `ref` are equal
  — there is no hidden state. `digest/1` derives a deterministic,
  collision-resistant storage-key fragment from that identity so two
  gateway replicas (or the same replica after a restart) always compute
  the same cache storage path for the same scope, with no coordination
  beyond the CacheScope value itself.
  """

  @enforce_keys [:ref, :repo]
  defstruct [:ref, :repo]

  @type t :: %__MODULE__{
          ref: String.t(),
          repo: String.t()
        }

  @doc """
  Builds a `CacheScope` from field values, validating basic shape: both
  `ref` and `repo` must be non-empty binaries. Returns
  `{:error, :invalid_cache_scope}` for anything else rather than raising.
  """
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_cache_scope}
  def new(ref, repo)
      when is_binary(ref) and byte_size(ref) > 0 and
             is_binary(repo) and byte_size(repo) > 0 do
    {:ok, %__MODULE__{ref: ref, repo: repo}}
  end

  def new(_ref, _repo), do: {:error, :invalid_cache_scope}

  @doc """
  The ordered list of scopes a cache lookup walks for this scope's
  `repo`: the scope itself first, then (if different) the same repo
  scoped to `default_ref`.

  Deduplicated — when `scope.ref` already equals `default_ref` the chain
  has exactly one element, since falling back to the same ref a lookup
  already missed on would find nothing new. Order matters: callers must
  probe the store in list order and stop at the first hit, so a
  branch-local cache always wins over the default-branch fallback.

  `default_ref` must be a non-empty binary; returns
  `{:error, :invalid_cache_scope}` otherwise rather than raising, mirroring
  `new/2`.
  """
  @spec lookup_chain(t(), String.t()) :: {:ok, [t()]} | {:error, :invalid_cache_scope}
  def lookup_chain(%__MODULE__{ref: ref, repo: repo} = scope, default_ref)
      when is_binary(default_ref) and byte_size(default_ref) > 0 do
    if ref == default_ref do
      {:ok, [scope]}
    else
      {:ok, [scope, %__MODULE__{ref: default_ref, repo: repo}]}
    end
  end

  def lookup_chain(%__MODULE__{}, _default_ref), do: {:error, :invalid_cache_scope}

  @doc """
  A deterministic, collision-resistant hex digest of this scope, derived
  from `(repo, ref)` via `:crypto.hash(:sha256, ...)`. Used to namespace
  cache storage keys/paths so two scopes never collide and the same
  scope always maps to the same path, on any gateway replica, before or
  after a restart — no coordination beyond the scope value itself.

  Pure and deterministic: identical `(repo, ref)` always yields an
  identical digest; any difference in either field yields a different
  one (the two fields are joined with a separator byte that cannot
  appear inside either field's own bytes, so `("a", "bc")` and `("ab",
  "c")` do not collide).
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{ref: ref, repo: repo}) do
    :crypto.hash(:sha256, [repo, <<0>>, ref])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Renders a `CacheScope` to the Kubernetes/HTTP JSON wire map (camelCase
  keys), suitable for `Jason.encode!/1`.
  """
  @spec to_wire(t()) :: %{String.t() => String.t()}
  def to_wire(%__MODULE__{ref: ref, repo: repo}) do
    %{"ref" => ref, "repo" => repo}
  end

  @doc """
  Parses a JSON wire map (string-keyed, as produced by `Jason.decode!/1`)
  into a `CacheScope`. Rejects maps missing either field, or with a field
  of the wrong type, returning `{:error, :invalid_cache_scope}` rather
  than raising — out-of-shape wire data is never silently coerced.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_cache_scope}
  def from_wire(%{"ref" => ref, "repo" => repo}) when is_binary(ref) and is_binary(repo) do
    new(ref, repo)
  end

  def from_wire(_other), do: {:error, :invalid_cache_scope}
end
