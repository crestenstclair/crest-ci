defmodule MockK8s.WatchHubTest do
  use ExUnit.Case, async: true

  alias MockK8s.WatchHub

  defp event(rv, opts \\ []) do
    %{
      type: Keyword.get(opts, :type, :modified),
      gvk: Keyword.get(opts, :gvk, "batch/v1/RunnerJob"),
      namespace: Keyword.get(opts, :namespace, "default"),
      resource_version: to_string(rv),
      object: %{"metadata" => %{"resourceVersion" => to_string(rv)}}
    }
  end

  describe "ordering and no gaps" do
    test "a subscriber receives events strictly in resourceVersion order with no gaps for its scope" do
      {:ok, hub} = WatchHub.start_link([])

      {:ok, watch_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "default",
          from_resource_version: ""
        })

      for rv <- 1..5 do
        assert :ok = WatchHub.notify(hub, event(rv))
      end

      delivered =
        for _ <- 1..5 do
          assert_receive {:watch_event, ^watch_ref, ev}, 200
          ev.resource_version
        end

      assert delivered == Enum.map(1..5, &to_string/1)
    end

    test "events for a different gvk or namespace are not delivered to an out-of-scope watch" do
      {:ok, hub} = WatchHub.start_link([])

      {:ok, watch_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "default",
          from_resource_version: ""
        })

      :ok = WatchHub.notify(hub, event(1, gvk: "batch/v1/WorkflowRun"))
      :ok = WatchHub.notify(hub, event(2, namespace: "other"))
      :ok = WatchHub.notify(hub, event(3))

      assert_receive {:watch_event, ^watch_ref, ev}, 200
      assert ev.resource_version == "3"
      refute_receive {:watch_event, ^watch_ref, _}, 50
    end

    test "a namespace of \"\" watches across all namespaces for the gvk" do
      {:ok, hub} = WatchHub.start_link([])

      {:ok, watch_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "",
          from_resource_version: ""
        })

      :ok = WatchHub.notify(hub, event(1, namespace: "ns-a"))
      :ok = WatchHub.notify(hub, event(2, namespace: "ns-b"))

      assert_receive {:watch_event, ^watch_ref, ev1}, 200
      assert_receive {:watch_event, ^watch_ref, ev2}, 200
      assert [ev1.resource_version, ev2.resource_version] == ["1", "2"]
    end

    test "subscribing replays retained backlog before delivering new live events, in order" do
      {:ok, hub} = WatchHub.start_link([])

      for rv <- 1..3, do: :ok = WatchHub.notify(hub, event(rv))

      {:ok, watch_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "default",
          from_resource_version: "1"
        })

      :ok = WatchHub.notify(hub, event(4))

      delivered =
        for _ <- 1..3 do
          assert_receive {:watch_event, ^watch_ref, ev}, 200
          ev.resource_version
        end

      assert delivered == ["2", "3", "4"]
    end
  end

  describe "gone on stale resourceVersion" do
    test "subscribing from a resourceVersion older than the retained backlog fails with :gone" do
      {:ok, hub} = WatchHub.start_link(backlog_limit: 2)

      for rv <- 1..5, do: :ok = WatchHub.notify(hub, event(rv))

      assert {:error, :gone} =
               WatchHub.subscribe(hub, %{
                 gvk: "batch/v1/RunnerJob",
                 namespace: "default",
                 from_resource_version: "1"
               })
    end

    test "from_resource_version \"0\" always replays the full retained backlog, never :gone" do
      {:ok, hub} = WatchHub.start_link(backlog_limit: 2)

      for rv <- 1..5, do: :ok = WatchHub.notify(hub, event(rv))

      assert {:ok, watch_ref} =
               WatchHub.subscribe(hub, %{
                 gvk: "batch/v1/RunnerJob",
                 namespace: "default",
                 from_resource_version: "0"
               })

      assert_receive {:watch_event, ^watch_ref, ev1}, 200
      assert_receive {:watch_event, ^watch_ref, ev2}, 200
      assert [ev1.resource_version, ev2.resource_version] == ["4", "5"]
      refute_receive {:watch_event, ^watch_ref, _}, 50
    end

    test "subscribing from a resourceVersion within the retained window succeeds" do
      {:ok, hub} = WatchHub.start_link(backlog_limit: 5)

      for rv <- 1..5, do: :ok = WatchHub.notify(hub, event(rv))

      assert {:ok, _watch_ref} =
               WatchHub.subscribe(hub, %{
                 gvk: "batch/v1/RunnerJob",
                 namespace: "default",
                 from_resource_version: "1"
               })
    end
  end

  describe "slow subscriber isolation" do
    test "a subscriber that overflows its mailbox bound is terminated without blocking the writer or other subscribers" do
      {:ok, hub} = WatchHub.start_link(mailbox_limit: 3)
      test_pid = self()

      # "Fast" subscriber lives on a separate process that actively drains
      # every event it receives and reports what it saw back to the test.
      fast =
        spawn(fn ->
          {:ok, fast_ref} =
            WatchHub.subscribe(hub, %{
              gvk: "batch/v1/RunnerJob",
              namespace: "default",
              from_resource_version: ""
            })

          send(test_pid, {:fast_subscribed, fast_ref})
          drain_forever(fast_ref, test_pid, 0)
        end)

      assert_receive {:fast_subscribed, fast_ref}, 200

      # "Slow" subscriber is this test process itself: it registers, then
      # deliberately does not drain its mailbox while the write storm below
      # runs, simulating a stalled reader.
      {:ok, slow_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "default",
          from_resource_version: ""
        })

      # Drive enough writes to exceed the slow subscriber's mailbox bound.
      # Every notify/2 call must still return :ok promptly — the writer is
      # never blocked by the slow subscriber's build-up.
      results = for rv <- 1..10, do: WatchHub.notify(hub, event(rv))
      assert Enum.all?(results, &(&1 == :ok))

      assert_receive {:watch_terminated, ^slow_ref, :overflow}, 200

      # the fast/other watch is unaffected: it drained events throughout and
      # was never terminated.
      refute_receive {:fast_terminated, ^fast_ref}, 50
      assert_receive {:fast_saw, ^fast_ref, count}, 500
      assert count > 0

      Process.exit(fast, :kill)
    end

    defp drain_forever(watch_ref, report_to, count) do
      receive do
        {:watch_event, ^watch_ref, _ev} ->
          drain_forever(watch_ref, report_to, count + 1)

        {:watch_terminated, ^watch_ref, _} ->
          send(report_to, {:fast_terminated, watch_ref})
      after
        150 ->
          send(report_to, {:fast_saw, watch_ref, count})
      end
    end
  end

  describe "unsubscribe" do
    test "unsubscribing stops further delivery" do
      {:ok, hub} = WatchHub.start_link([])

      {:ok, watch_ref} =
        WatchHub.subscribe(hub, %{
          gvk: "batch/v1/RunnerJob",
          namespace: "default",
          from_resource_version: ""
        })

      :ok = WatchHub.unsubscribe(hub, watch_ref)
      :ok = WatchHub.notify(hub, event(1))

      refute_receive {:watch_event, ^watch_ref, _}, 100
    end
  end
end
