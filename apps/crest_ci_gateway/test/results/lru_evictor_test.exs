defmodule CrestCiGateway.Results.LruEvictorTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheEntry
  alias CrestCiGateway.Results.LruEvictor

  defp entry!(key, scope, size_bytes, state, version, created_at, last_used_at) do
    {:ok, entry} =
      CacheEntry.new(key, scope, size_bytes, state, version, created_at, last_used_at)

    entry
  end

  describe "evict/2" do
    test "returns empty list when occupied bytes already fit the budget" do
      entries = [
        entry!("k1", "s", 100, :committed, "v1", "t0", "t1"),
        entry!("k2", "s", 100, :committed, "v1", "t0", "t2")
      ]

      assert LruEvictor.evict(entries, 1_000) == []
    end

    test "returns empty list for an empty entry set regardless of budget" do
      assert LruEvictor.evict([], 0) == []
    end

    test "evicts oldest last_used_at first" do
      oldest = entry!("k1", "s", 100, :committed, "v1", "t0", "2024-01-01T00:00:00Z")
      middle = entry!("k2", "s", 100, :committed, "v1", "t0", "2024-01-02T00:00:00Z")
      newest = entry!("k3", "s", 100, :committed, "v1", "t0", "2024-01-03T00:00:00Z")

      # total = 300, budget = 100 -> must free 200 bytes -> evict oldest, then middle
      result = LruEvictor.evict([newest, oldest, middle], 100)

      assert result == [oldest, middle]
    end

    test "evicts the minimal number of entries needed to satisfy the budget" do
      oldest = entry!("k1", "s", 50, :committed, "v1", "t0", "2024-01-01T00:00:00Z")
      middle = entry!("k2", "s", 50, :committed, "v1", "t0", "2024-01-02T00:00:00Z")
      newest = entry!("k3", "s", 50, :committed, "v1", "t0", "2024-01-03T00:00:00Z")

      # total = 150, budget = 120 -> must free 30 bytes -> evicting just the
      # oldest (50 bytes) already satisfies the budget; stop there.
      result = LruEvictor.evict([oldest, middle, newest], 120)

      assert result == [oldest]
    end

    test "never evicts Reserved entries even when they dominate occupied bytes" do
      reserved = entry!("k1", "s", 900, :reserved, "v1", "t0", "2024-01-01T00:00:00Z")
      committed = entry!("k2", "s", 100, :committed, "v1", "t0", "2024-01-02T00:00:00Z")

      # total = 1000, budget = 100 -> must free 900, but only 100 committed
      # bytes exist to evict -> evict all committed entries, reserved
      # entries are untouched regardless of remaining overage.
      result = LruEvictor.evict([reserved, committed], 100)

      assert result == [committed]
      refute Enum.any?(result, &(&1.state == :reserved))
    end

    test "returns all committed entries when reserved bytes alone exceed the budget" do
      reserved = entry!("k1", "s", 500, :reserved, "v1", "t0", "2024-01-01T00:00:00Z")
      committed1 = entry!("k2", "s", 100, :committed, "v1", "t0", "2024-01-02T00:00:00Z")
      committed2 = entry!("k3", "s", 100, :committed, "v1", "t0", "2024-01-03T00:00:00Z")

      result = LruEvictor.evict([reserved, committed1, committed2], 50)

      assert Enum.sort(result) == Enum.sort([committed1, committed2])
    end

    test "breaks ties on identical last_used_at deterministically by identity then version" do
      a = entry!("k-a", "s", 10, :committed, "v1", "t0", "same")
      b = entry!("k-b", "s", 10, :committed, "v1", "t0", "same")

      result1 = LruEvictor.evict([b, a], 0)
      result2 = LruEvictor.evict([a, b], 0)

      assert result1 == result2
      assert result1 == [a, b]
    end

    test "is idempotent — repeated calls with the same input return the same result" do
      entries = [
        entry!("k1", "s", 40, :committed, "v1", "t0", "2024-01-01T00:00:00Z"),
        entry!("k2", "s", 40, :committed, "v1", "t0", "2024-01-02T00:00:00Z"),
        entry!("k3", "s", 40, :reserved, "v1", "t0", "2024-01-03T00:00:00Z")
      ]

      assert LruEvictor.evict(entries, 50) == LruEvictor.evict(entries, 50)
    end
  end
end
