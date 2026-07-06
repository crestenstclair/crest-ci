defmodule CrestCiGateway.Results.LocalFsCacheStoreTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.Results.CacheStore
  alias CrestCiGateway.Results.LocalFsCacheStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "local_fs_cache_store_test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, scope} = CacheScope.new("refs/heads/main", "acme/widgets")
    {:ok, root: root, store: LocalFsCacheStore.new(root), scope: scope}
  end

  test "reserve, upload, commit round-trips through lookup", %{store: store, scope: scope} do
    assert {:ok, reservation} = CacheStore.reserve(store, "deps-hit", "v1", scope)
    assert :ok = CacheStore.upload(store, reservation, 0, "cached-bytes")
    assert {:ok, entry} = CacheStore.commit(store, reservation, byte_size("cached-bytes"))
    assert entry.key == "deps-hit"
    assert entry.size_bytes == byte_size("cached-bytes")

    assert {:ok, hit_entry, "cached-bytes"} = CacheStore.lookup(store, "deps-hit", [], [scope])
    assert hit_entry.key == "deps-hit"
  end

  test "reserve rejects a key that already names a Committed entry", %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-otp27-a1b2c3", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "hello")
    {:ok, _entry} = CacheStore.commit(store, reservation, 5)

    assert {:error, :already_committed} =
             CacheStore.reserve(store, "deps-otp27-a1b2c3", "v2", scope)
  end

  test "upload is idempotent by (reservation, offset): first write at an offset wins", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-idempotent", "v1", scope)

    assert :ok = CacheStore.upload(store, reservation, 0, "hello ")
    assert :ok = CacheStore.upload(store, reservation, 6, "world")
    # Resend offset 0 with different content: the first write wins.
    assert :ok = CacheStore.upload(store, reservation, 0, "HELLO")

    assert {:ok, entry} = CacheStore.commit(store, reservation, 11)
    assert entry.size_bytes == 11

    assert {:ok, _entry, "hello world"} = CacheStore.lookup(store, "deps-idempotent", [], [scope])
  end

  test "commit rejects a size mismatch and leaves nothing servable under that key", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-bad-size", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "hello")

    assert {:error, :size_mismatch} = CacheStore.commit(store, reservation, 999)
    assert :miss = CacheStore.lookup(store, "deps-bad-size", [], [scope])
  end

  test "lookup on an unknown key is a soft miss, never an error", %{store: store, scope: scope} do
    assert :miss = CacheStore.lookup(store, "never-committed", ["deps-"], [scope])
  end

  test "lookup touches lastUsedAt on a hit", %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-touch", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "x")
    {:ok, committed} = CacheStore.commit(store, reservation, 1)

    assert {:ok, touched, "x"} = CacheStore.lookup(store, "deps-touch", [], [scope])
    assert touched.last_used_at >= committed.last_used_at
  end

  test "committed entries survive a restart (index reloaded from disk)", %{
    root: root,
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-restart", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "durable")
    {:ok, _entry} = CacheStore.commit(store, reservation, byte_size("durable"))

    restarted_store = LocalFsCacheStore.new(root)

    assert {:ok, entry, "durable"} =
             CacheStore.lookup(restarted_store, "deps-restart", [], [scope])

    assert entry.key == "deps-restart"
  end

  test "evict returns an empty list when total size is within budget", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-small", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "tiny")
    {:ok, _entry} = CacheStore.commit(store, reservation, 4)

    assert {:ok, []} = CacheStore.evict(store, 1_000_000)
  end

  test "evict removes candidates once total size exceeds budget, and they stop being servable", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-big", "v1", scope)
    content = String.duplicate("x", 100)
    :ok = CacheStore.upload(store, reservation, 0, content)
    {:ok, _entry} = CacheStore.commit(store, reservation, 100)

    assert {:ok, [evicted]} = CacheStore.evict(store, 10)
    assert evicted.key == "deps-big"

    assert :miss = CacheStore.lookup(store, "deps-big", [], [scope])
  end
end
