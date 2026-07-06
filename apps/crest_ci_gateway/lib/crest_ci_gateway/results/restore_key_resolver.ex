defmodule CrestCiGateway.Results.RestoreKeyResolver do
  @moduledoc """
  Domain Service: `domainService.Results.RestoreKeyResolver` — pure cache
  lookup arbitration.

  Given a lookup `key`, an ordered list of `restore_keys` (prefix
  fallbacks), a `scope_chain` (the ordered visibility chain a lookup is
  allowed to see — see `CrestCiGateway.Results.CacheScope.lookup_chain/2`,
  nearest scope first), and the full set of known `CacheEntry` structs,
  `resolve/4` decides which single entry (if any) a runner's
  cache-restore request should be served, following GitHub Actions cache
  semantics:

    1. An exact `key` match wins immediately, in the nearest scope that
       has one — scopes further down the chain are never even
       considered once a nearer scope has an exact hit, and restore_keys
       are never consulted once an exact hit exists anywhere in the
       chain.
    2. Otherwise, entries are matched against `restore_keys` as
       (byte-for-byte, case-sensitive) prefixes. The **longest** matching
       restore-key prefix wins, regardless of `restore_keys` list order;
       ties on prefix length are broken by nearest scope, then by most
       recently created entry.
    3. Entries whose scope is not present in `scope_chain` are invisible
       to the lookup — they cannot win under any rule, no matter how
       good their key match is. Non-`:committed` entries (per
       `CacheEntry.servable?/1`) are likewise never returned: a
       `:reserved` entry's blob may not exist yet, or may never
       complete.

  This module is a pure function over its four arguments: no I/O, no
  process state, no side channel, no time-of-call dependency — safe to
  call from any process, any number of times, with the same result for
  the same inputs. It never talks to `CrestCiGateway`'s blob store or the
  Kubernetes API directly; callers (e.g. a `CacheStore` adapter's
  `lookup/4`) are responsible for gathering candidate entries and for
  translating the `{:ok, entry} | :miss` result into an HTTP response —
  including touching the winning entry's `last_used_at`, which is an
  adapter-side effect, not this module's concern.

  ## Scope and key representation

  `CacheEntry.key` and `CacheEntry.scope` are bare, opaque strings (see
  `CrestCiGateway.Results.CacheEntry`'s moduledoc), not the struct-wrapped
  `CacheKey` / `CacheScope` value objects used at parsing boundaries.
  This module accepts `key` as a bare string (the same representation
  `CacheEntry.key` and `CrestCiGateway.Results.CacheStore`'s `lookup/4`
  port already use) and bridges `scope_chain` — a list of `%CacheScope{}`
  structs — to that bare representation via
  `CrestCiGateway.Results.CacheScope.digest/1`: an entry is visible under
  a chain scope iff `entry.scope == CacheScope.digest(scope)`. All key
  and prefix comparisons are plain binary equality / `String.starts_with?/2`
  — never trimmed, never case-folded — matching `CacheKey`'s
  case-sensitive comparison invariant.
  """

  alias CrestCiGateway.Results.{CacheEntry, CacheScope}

  @typedoc "A restore-key prefix string, as supplied by the workflow author."
  @type restore_key :: String.t()

  @doc """
  Resolves the entry (if any) to serve for a cache-restore lookup.

  `key` is the exact cache key requested (bare string, case-sensitive).
  `restore_keys` is the list of prefix fallbacks — order does not affect
  the result; the longest matching prefix always wins, and ties are
  broken by scope nearness and then recency, never by list position.
  `scope_chain` is the ordered visibility chain, nearest scope first
  (typically `CacheScope.lookup_chain/2`'s result). `entries` is every
  known `CacheEntry` (any state, any scope) — filtering to committed,
  in-chain entries is this function's job, not the caller's.

  Returns `{:ok, entry}` for a hit, `:miss` when nothing in scope
  matches.
  """
  @spec resolve(String.t(), [restore_key()], [CacheScope.t()], [CacheEntry.t()]) ::
          {:ok, CacheEntry.t()} | :miss
  def resolve(key, restore_keys, scope_chain, entries)
      when is_binary(key) and is_list(restore_keys) and is_list(scope_chain) and
             is_list(entries) do
    ranked = rank_by_scope(scope_chain)
    visible = visible_committed_entries(entries, ranked)

    case exact_match(key, visible) do
      {:ok, entry} -> {:ok, entry}
      :miss -> restore_key_match(restore_keys, visible)
    end
  end

  # -- exact match ---------------------------------------------------------

  # Nearest scope wins outright; a tie within the same scope (which
  # should not arise under normal reservation/commit discipline, but is
  # handled deterministically rather than left to list order) is broken
  # by most recently created.
  defp exact_match(key, visible) do
    visible
    |> Enum.filter(fn {entry, _rank} -> entry.key === key end)
    |> Enum.sort_by(fn {entry, _rank} -> entry.created_at end, :desc)
    |> Enum.sort_by(fn {_entry, rank} -> rank end, :asc)
    |> case do
      [{entry, _rank} | _rest] -> {:ok, entry}
      [] -> :miss
    end
  end

  # -- restore-key prefix match ---------------------------------------------

  # Longest matching prefix wins first, nearest scope second, most
  # recently created third. Built by expanding every (restore_key, entry)
  # match into its own candidate tagged with the prefix length that
  # produced it, then sorting least-significant-criterion-first —
  # Elixir's sort is stable, so chaining ascending/descending sorts from
  # the least to the most significant key composes them correctly
  # regardless of `restore_keys`' own order.
  defp restore_key_match(restore_keys, visible) do
    restore_keys
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(fn restore_key ->
      visible
      |> Enum.filter(fn {entry, _rank} -> String.starts_with?(entry.key, restore_key) end)
      |> Enum.map(fn {entry, rank} -> {entry, rank, byte_size(restore_key)} end)
    end)
    |> Enum.sort_by(fn {entry, _rank, _prefix_len} -> entry.created_at end, :desc)
    |> Enum.sort_by(fn {_entry, rank, _prefix_len} -> rank end, :asc)
    |> Enum.sort_by(fn {_entry, _rank, prefix_len} -> prefix_len end, :desc)
    |> case do
      [{entry, _rank, _prefix_len} | _rest] -> {:ok, entry}
      [] -> :miss
    end
  end

  # -- shared helpers --------------------------------------------------------

  # Maps each chain scope's digest to its position (0 = nearest). A
  # scope repeated in the chain keeps its nearest (lowest) index.
  defp rank_by_scope(scope_chain) do
    scope_chain
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {scope, index}, acc ->
      Map.put_new(acc, CacheScope.digest(scope), index)
    end)
  end

  # Entries that are servable (committed) and whose scope digest appears
  # somewhere in the chain, paired with that scope's chain rank.
  # Entries whose scope is absent from `ranked` are dropped entirely —
  # invisible, not merely deprioritized.
  defp visible_committed_entries(entries, ranked) do
    entries
    |> Enum.filter(&CacheEntry.servable?/1)
    |> Enum.map(fn entry -> {entry, Map.get(ranked, entry.scope)} end)
    |> Enum.reject(fn {_entry, rank} -> is_nil(rank) end)
  end
end
