defmodule SimRunner.Demo.LocalCacheStoreTest do
  use ExUnit.Case, async: true

  alias SimRunner.Demo.LocalCacheStore

  setup do
    root = Path.join(System.tmp_dir!(), "cache_store_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "restoring an unsaved key is a soft miss, never an error", %{root: root} do
    assert :miss = LocalCacheStore.restore(root, "never-saved")
  end

  test "a saved key is restorable byte-identically", %{root: root} do
    assert :ok = LocalCacheStore.save(root, "my-key", "cached-bytes")
    assert {:ok, "cached-bytes"} = LocalCacheStore.restore(root, "my-key")
  end

  test "distinct keys never collide", %{root: root} do
    assert :ok = LocalCacheStore.save(root, "key-a", "content-a")
    assert :ok = LocalCacheStore.save(root, "key-b", "content-b")

    assert {:ok, "content-a"} = LocalCacheStore.restore(root, "key-a")
    assert {:ok, "content-b"} = LocalCacheStore.restore(root, "key-b")
  end

  test "keys containing path separators are safely namespaced on disk", %{root: root} do
    assert :ok = LocalCacheStore.save(root, "../../etc/passwd", "safe")
    assert {:ok, "safe"} = LocalCacheStore.restore(root, "../../etc/passwd")
    refute File.exists?(Path.join(root, "../../etc/passwd"))
  end
end
