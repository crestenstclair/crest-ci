defmodule CrestCiController.LeaderElectorTest do
  use ExUnit.Case, async: true

  alias CrestCiController.LeaderElector
  alias CrestCiController.Test.FakeKubeClient
  alias CrestCiContract.LeaseSpec

  @gvk {"coordination.k8s.io", "v1", "Lease"}
  @namespace "crest-ci-system"
  @lease_name "crest-ci-controller"

  # Fast timings so tests observe transitions quickly via message-passing,
  # never via blind sleeps.
  @fast_timings %{
    lease_duration_seconds: 1,
    renew_interval_ms: 100,
    retry_interval_ms: 50
  }

  setup do
    {:ok, agent} = FakeKubeClient.start_link()
    {:ok, conn: agent, kube_conn: {FakeKubeClient, agent}}
  end

  test "acquires an unheld lease and reports leader?/1 true", %{kube_conn: kube_conn} do
    {:ok, pid} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    :ok = LeaderElector.subscribe(pid, self())

    assert_receive {:leader_acquired, "instance-a"}, 2_000
    assert LeaderElector.leader?(pid)
  end

  test "exactly one of two contenders becomes leader on a fresh lease", %{kube_conn: kube_conn} do
    {:ok, pid_a} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    {:ok, pid_b} = LeaderElector.start_link(kube_conn, "instance-b", @fast_timings)
    :ok = LeaderElector.subscribe(pid_a, self())
    :ok = LeaderElector.subscribe(pid_b, self())

    assert_receive {:leader_acquired, winner}, 2_000
    assert winner in ["instance-a", "instance-b"]

    # Give the loser a couple of retry cycles to observe the held lease and
    # settle as a non-leader (message-driven: we just wait for its own tick
    # cadence via the deterministic leader?/1 poll below, bounded in time).
    wait_until(fn ->
      LeaderElector.leader?(pid_a) != LeaderElector.leader?(pid_b)
    end)

    assert [LeaderElector.leader?(pid_a), LeaderElector.leader?(pid_b)]
           |> Enum.count(& &1) == 1
  end

  test "a leader renews inside the lease duration and never lapses", %{kube_conn: kube_conn} do
    {:ok, pid} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    :ok = LeaderElector.subscribe(pid, self())

    assert_receive {:leader_acquired, "instance-a"}, 2_000

    # Outlive several renew intervals (well inside the lease duration) and
    # confirm no loss notification arrives and leader?/1 still holds.
    refute_receive {:leader_lost, _identity}, 600
    assert LeaderElector.leader?(pid)
  end

  test "a stale, expired lease from a dead holder is taken over", %{
    conn: conn,
    kube_conn: kube_conn
  } do
    long_expired_time =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    {:ok, stale_spec} = LeaseSpec.new(long_expired_time, "dead-instance", 1, 0, long_expired_time)

    stale_object = %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{"name" => @lease_name, "namespace" => @namespace},
      "spec" => LeaseSpec.to_wire(stale_spec)
    }

    {:ok, _created} = FakeKubeClient.create(conn, @gvk, @namespace, stale_object)

    {:ok, pid} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    :ok = LeaderElector.subscribe(pid, self())

    assert_receive {:leader_acquired, "instance-a"}, 2_000
    assert LeaderElector.leader?(pid)

    {:ok, stored} = FakeKubeClient.get(conn, @gvk, @namespace, @lease_name)
    {:ok, stored_spec} = LeaseSpec.from_wire(stored["spec"])
    assert stored_spec.holder_identity == "instance-a"
    assert stored_spec.lease_transitions == 1
  end

  test "clean shutdown releases the lease so another instance acquires immediately", %{
    kube_conn: kube_conn
  } do
    long_timings = %{
      lease_duration_seconds: 30,
      renew_interval_ms: 100,
      retry_interval_ms: 50
    }

    {:ok, pid_a} = LeaderElector.start_link(kube_conn, "instance-a", long_timings)
    :ok = LeaderElector.subscribe(pid_a, self())
    assert_receive {:leader_acquired, "instance-a"}, 2_000

    :ok = GenServer.stop(pid_a, :normal)

    {:ok, pid_b} = LeaderElector.start_link(kube_conn, "instance-b", long_timings)
    :ok = LeaderElector.subscribe(pid_b, self())

    # Even though the lease duration is 30s, a clean step-down releases it,
    # so the successor acquires quickly rather than waiting out the lease.
    assert_receive {:leader_acquired, "instance-b"}, 2_000
  end

  test "leader?/1 always returns a plain boolean, never a raw election-in-progress state",
       %{kube_conn: kube_conn} do
    {:ok, pid} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    assert is_boolean(LeaderElector.leader?(pid))
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within deadline")
      else
        Process.sleep(10)
        wait_until(fun, deadline)
      end
    end
  end
end
