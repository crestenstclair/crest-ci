defmodule CrestCiGateway.Results.LocalFsActionCacheTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ActionProxy
  alias CrestCiGateway.Results.LocalFsActionCache
  alias CrestCiGateway.Results.LocalFsActionCache.SingleFlight

  defp tmp_root(test_name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "action_cache_test_#{test_name}_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp start_singleflight! do
    {:ok, pid} = SingleFlight.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp expected_path(root, repo, ref) do
    Path.join([root, "actions", String.replace(repo, "/", "-"), ref <> ".tgz"])
  end

  # Waits for an observable state transition (never a blind sleep-and-hope):
  # polls `check.()` until it returns true, so callers can deterministically
  # know e.g. "N followers have joined this claim" before proceeding.
  defp wait_until(check, attempts \\ 200)

  defp wait_until(_check, 0), do: flunk("condition did not become true in time")

  defp wait_until(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      wait_until(check, attempts - 1)
    end
  end

  describe "resolve/3" do
    test "fetches a new (repo, ref) exactly once and returns its content-addressed path" do
      root = tmp_root("fetch_once")
      test_pid = self()

      fetcher = fn repo, ref, dest ->
        send(test_pid, {:fetched, repo, ref})
        File.write!(dest, "tarball")
        :ok
      end

      proxy = LocalFsActionCache.new(fetcher, start_singleflight!(), root)

      assert {:ok, path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert path == expected_path(root, "actions/checkout", "v4")
      assert File.regular?(path)
      assert_received {:fetched, "actions/checkout", "v4"}
    end

    test "a subsequent resolve of an already-cached key is a cache hit and never invokes the fetcher" do
      root = tmp_root("cache_hit")
      test_pid = self()

      fetcher = fn repo, ref, dest ->
        send(test_pid, {:fetched, repo, ref})
        File.write!(dest, "tarball")
        :ok
      end

      proxy = LocalFsActionCache.new(fetcher, start_singleflight!(), root)

      assert {:ok, path} = ActionProxy.resolve(proxy, "actions/setup-node", "v5")
      assert_received {:fetched, "actions/setup-node", "v5"}

      assert {:ok, ^path} = ActionProxy.resolve(proxy, "actions/setup-node", "v5")
      refute_received {:fetched, _repo, _ref}
    end

    test "a pre-existing cached tarball on disk is a cache hit even on the very first resolve call" do
      root = tmp_root("preexisting")
      path = expected_path(root, "actions/checkout", "v3")
      :ok = File.mkdir_p(Path.dirname(path))
      :ok = File.write(path, "already there")

      fetcher = fn _repo, _ref, _dest -> flunk("fetcher must not be invoked on a cache hit") end

      proxy = LocalFsActionCache.new(fetcher, start_singleflight!(), root)

      assert {:ok, ^path} = ActionProxy.resolve(proxy, "actions/checkout", "v3")
    end

    test "different refs of the same repo are cached independently" do
      root = tmp_root("distinct_refs")
      test_pid = self()

      fetcher = fn repo, ref, dest ->
        send(test_pid, {:fetched, repo, ref})
        File.write!(dest, "tarball for #{ref}")
        :ok
      end

      proxy = LocalFsActionCache.new(fetcher, start_singleflight!(), root)

      assert {:ok, path_v3} = ActionProxy.resolve(proxy, "actions/checkout", "v3")
      assert {:ok, path_v4} = ActionProxy.resolve(proxy, "actions/checkout", "v4")

      assert path_v3 != path_v4
      assert_received {:fetched, "actions/checkout", "v3"}
      assert_received {:fetched, "actions/checkout", "v4"}
    end

    test "concurrent resolves of the same key fetch exactly once and every caller observes the same result" do
      root = tmp_root("concurrent")
      test_pid = self()

      fetcher = fn repo, ref, dest ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :release -> :ok
        end

        File.write!(dest, "tarball for #{repo}@#{ref}")
        :ok
      end

      singleflight = start_singleflight!()
      proxy = LocalFsActionCache.new(fetcher, singleflight, root)

      tasks =
        for _ <- 1..8 do
          Task.async(fn -> ActionProxy.resolve(proxy, "actions/checkout", "v4") end)
        end

      assert_receive {:fetch_started, fetcher_pid}, 1_000

      # Deterministically wait for the other 7 tasks to have joined this
      # claim as followers before releasing the leader, so the leader
      # cannot finish (and free the key) while a follower is still racing
      # to register — which would otherwise let it start a fresh claim and
      # invoke the fetcher a second time.
      wait_until(fn ->
        SingleFlight.waiting_count(singleflight, {root, "actions/checkout", "v4"}) == 7
      end)

      send(fetcher_pid, :release)

      results = Task.await_many(tasks, 1_000)

      expected = {:ok, expected_path(root, "actions/checkout", "v4")}
      assert Enum.all?(results, &(&1 == expected))

      # The single-flight claim guarantees the fetcher runs at most once for
      # this key: by the time every task has completed, any wrongful second
      # invocation would already have sent its message.
      refute_received {:fetch_started, _other_pid}
    end

    test "a failed fetch propagates the error and does not poison the key for the next resolve" do
      root = tmp_root("failed_fetch")
      test_pid = self()

      fetcher = fn repo, ref, dest ->
        send(test_pid, {:attempt, repo, ref})

        if Process.get(:already_failed_once) do
          File.write!(dest, "tarball")
          :ok
        else
          Process.put(:already_failed_once, true)
          {:error, :network_unreachable}
        end
      end

      proxy = LocalFsActionCache.new(fetcher, start_singleflight!(), root)

      assert {:error, :network_unreachable} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      refute File.regular?(expected_path(root, "actions/checkout", "v4"))

      assert {:ok, path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert File.regular?(path)
    end
  end

  describe "SingleFlight.run/3" do
    test "runs the function once for concurrent callers of the same key" do
      {:ok, server} = SingleFlight.start_link([])
      test_pid = self()

      # The leader blocks on a gate before finishing, so every follower Task
      # below is guaranteed to have joined the same in-flight claim before
      # the leader (and therefore the whole round) completes.
      fun = fn ->
        send(test_pid, {:ran, self()})

        receive do
          :go -> {:ok, :done}
        end
      end

      tasks = for _ <- 1..5, do: Task.async(fn -> SingleFlight.run(server, :same_key, fun) end)

      assert_receive {:ran, leader_pid}, 1_000
      wait_until(fn -> SingleFlight.waiting_count(server, :same_key) == 4 end)
      send(leader_pid, :go)

      results = Task.await_many(tasks, 1_000)
      assert results == List.duplicate({:ok, :done}, 5)

      refute_received {:ran, _pid}
    end

    test "distinct keys never single-flight against each other" do
      {:ok, server} = SingleFlight.start_link([])

      assert SingleFlight.run(server, :key_a, fn -> {:ok, :a} end) == {:ok, :a}
      assert SingleFlight.run(server, :key_b, fn -> {:ok, :b} end) == {:ok, :b}
    end

    test "an exception raised by the leader's function is delivered to followers as an error, not a hang" do
      {:ok, server} = SingleFlight.start_link([])
      test_pid = self()

      leader_fun = fn ->
        send(test_pid, :leader_running)

        receive do
          :go -> raise "boom"
        end
      end

      leader_task = Task.async(fn -> SingleFlight.run(server, :explosive, leader_fun) end)
      assert_receive :leader_running, 1_000

      follower_task =
        Task.async(fn -> SingleFlight.run(server, :explosive, fn -> {:ok, :unreachable} end) end)

      send(leader_task.pid, :go)

      assert {:error, {:exception, %RuntimeError{message: "boom"}}} =
               Task.await(leader_task, 1_000)

      assert {:error, {:exception, %RuntimeError{message: "boom"}}} =
               Task.await(follower_task, 1_000)
    end
  end
end
