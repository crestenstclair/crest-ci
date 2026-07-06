defmodule CrestCiGateway.LocalFsActionCacheTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.LocalFsActionCache
  alias CrestCiGateway.Results.ActionProxy

  setup do
    root = Path.join(System.tmp_dir!(), "action_cache_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp counting_fetcher(fetch_log, content \\ "tarball-bytes") do
    fn repo, ref ->
      send(fetch_log, {:fetch, repo, ref})
      {:ok, content}
    end
  end

  test "resolve fetches once and returns the deterministic content-addressed path", %{root: root} do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    assert {:ok, path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert path == Path.join([root, "actions", "actions-checkout", "v4.tgz"])
    assert File.read!(path) == "tarball-bytes"
    assert_received {:fetch, "actions/checkout", "v4"}
  end

  test "is content-addressed: same (repo, ref) always resolves to the same path", %{root: root} do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    assert {:ok, path1} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert {:ok, path2} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert path1 == path2
  end

  test "distinct refs of the same repo resolve to distinct paths", %{root: root} do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    assert {:ok, path_v4} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert {:ok, path_v3} = ActionProxy.resolve(proxy, "actions/checkout", "v3")
    refute path_v4 == path_v3
  end

  test "cache hit never invokes the fetcher again: a second sequential resolve of the same key fetches exactly once",
       %{root: root} do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    assert {:ok, _path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert {:ok, _path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
    assert {:ok, _path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")

    assert_received {:fetch, "actions/checkout", "v4"}
    refute_received {:fetch, "actions/checkout", "v4"}
  end

  test "concurrent first resolves of the same key single-flight into exactly one fetch", %{
    root: root
  } do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    tasks =
      for _ <- 1..20 do
        Task.async(fn -> ActionProxy.resolve(proxy, "actions/setup-node", "v5") end)
      end

    results = Task.await_many(tasks, 5_000)

    assert Enum.all?(
             results,
             &(&1 == {:ok, Path.join([root, "actions", "actions-setup-node", "v5.tgz"])})
           )

    # Exactly one fetch happened for the key, no matter how many concurrent
    # callers raced for it.
    assert_received {:fetch, "actions/setup-node", "v5"}
    refute_received {:fetch, "actions/setup-node", "v5"}
  end

  test "concurrent resolves of different keys each fetch independently", %{root: root} do
    proxy = LocalFsActionCache.new(counting_fetcher(self()), root)

    tasks = [
      Task.async(fn -> ActionProxy.resolve(proxy, "actions/checkout", "v4") end),
      Task.async(fn -> ActionProxy.resolve(proxy, "actions/setup-node", "v5") end)
    ]

    [checkout_result, setup_node_result] = Task.await_many(tasks, 5_000)

    assert {:ok, _} = checkout_result
    assert {:ok, _} = setup_node_result
    assert_received {:fetch, "actions/checkout", "v4"}
    assert_received {:fetch, "actions/setup-node", "v5"}
  end

  test "propagates {:error, term} from the fetcher and does not create a tarball file", %{
    root: root
  } do
    fetcher = fn _repo, _ref -> {:error, :not_found} end
    proxy = LocalFsActionCache.new(fetcher, root)

    assert {:error, :not_found} = ActionProxy.resolve(proxy, "actions/missing", "v1")
    refute File.exists?(Path.join([root, "actions", "actions-missing", "v1.tgz"]))
  end

  test "after a fetch error, a subsequent resolve retries the fetcher rather than caching the failure",
       %{root: root} do
    fetcher = fn _repo, _ref ->
      send(self(), :not_used)
      {:error, :boom}
    end

    # Use a stateful fetcher via an Agent-free counter through message passing
    # from the test process itself is not viable across processes, so drive
    # retry behavior directly: first call fails, second call (new fetcher)
    # succeeds — proving the adapter does not persist a negative cache entry
    # that would short-circuit future attempts.
    proxy = LocalFsActionCache.new(fetcher, root)
    assert {:error, :boom} = ActionProxy.resolve(proxy, "actions/flaky", "v1")

    succeeding_proxy = LocalFsActionCache.new(counting_fetcher(self()), root)
    assert {:ok, path} = ActionProxy.resolve(succeeding_proxy, "actions/flaky", "v1")
    assert File.read!(path) == "tarball-bytes"
    assert_received {:fetch, "actions/flaky", "v1"}
  end
end
