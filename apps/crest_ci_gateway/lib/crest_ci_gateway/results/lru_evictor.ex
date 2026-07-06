defmodule CrestCiGateway.Results.LruEvictor do
  @moduledoc """
  Domain Service: `domainService.Results.LruEvictor` — pure function
  computing which cache entries to evict to fit a byte budget.

  Given the full set of `CacheEntry` structs currently occupying cache
  storage (as projected from the Kubernetes-backed cache index) and a
  byte budget, `evict/2` returns the ordered list of entries that must be
  deleted so that occupied storage no longer exceeds the budget.

  Eviction order is oldest `last_used_at` first — the coldest entries go
  first, matching standard LRU semantics. `:reserved` entries are never
  eviction candidates: a reservation marks a cache upload in flight (the
  runner has claimed the slot but may not have finished uploading), and
  evicting it here — outside the CR-arbitrated reservation lifecycle —
  would silently destroy state another actor believes it still owns. Only
  `:committed` entries are ever selected.

  The result is minimal: entries are evicted one at a time, oldest first,
  stopping as soon as remaining occupied bytes are at or under the
  budget. No entry is evicted that isn't needed to satisfy the budget.

  If reserved bytes alone already exceed (or meet) the budget, evicting
  every committed entry still cannot satisfy it — `evict/2` returns all
  committed entries in that case (the minimal-effort best result; the
  budget violation persists until reservations resolve via their own
  lifecycle, which this pure function does not and cannot touch).

  This module is pure: no process state, no I/O, no time-of-call
  dependency. It is safe to call from any process, any number of times,
  with the same result for the same inputs — a hallmark of the
  level-triggered, replay-safe design this system requires everywhere.
  """

  alias CrestCiGateway.Results.CacheEntry

  @doc """
  Computes the eviction list for `entries` under `byte_budget` (in bytes).

  Returns entries to evict, oldest `last_used_at` first. `:reserved`
  entries are always excluded. Ties in `last_used_at` are broken
  deterministically by `(scope, key)` identity and then `version`, so
  repeated calls with the same input always produce the same order
  (required for idempotent, replay-safe reconciliation).

  Returns `[]` when occupied bytes (reserved + committed) already fit
  within `byte_budget` — no eviction needed.
  """
  @spec evict(list(CacheEntry.t()), non_neg_integer()) :: list(CacheEntry.t())
  def evict(entries, byte_budget)
      when is_list(entries) and is_integer(byte_budget) and byte_budget >= 0 do
    {reserved, committed} = Enum.split_with(entries, &(&1.state == :reserved))

    reserved_bytes = sum_bytes(reserved)
    committed_sorted = Enum.sort(committed, &oldest_first?/2)
    committed_bytes = sum_bytes(committed_sorted)

    occupied = reserved_bytes + committed_bytes

    if occupied <= byte_budget do
      []
    else
      bytes_to_free = occupied - byte_budget
      take_until_freed(committed_sorted, bytes_to_free)
    end
  end

  # Deterministic total order: last_used_at ascending, then identity, then
  # version, so equal-last_used_at entries always sort the same way.
  defp oldest_first?(%CacheEntry{} = a, %CacheEntry{} = b) do
    key_a = {a.last_used_at, CacheEntry.identity(a), a.version}
    key_b = {b.last_used_at, CacheEntry.identity(b), b.version}
    key_a <= key_b
  end

  defp sum_bytes(entries), do: Enum.reduce(entries, 0, fn e, acc -> acc + e.size_bytes end)

  # Walks the oldest-first list, accumulating evictions only until enough
  # bytes have been freed — never evicts more than the budget requires.
  defp take_until_freed(sorted, bytes_to_free) do
    {evicted, _remaining} =
      Enum.reduce_while(sorted, {[], bytes_to_free}, fn entry, {acc, remaining} ->
        if remaining <= 0 do
          {:halt, {acc, remaining}}
        else
          {:cont, {[entry | acc], remaining - entry.size_bytes}}
        end
      end)

    Enum.reverse(evicted)
  end
end
