defmodule CrestCiGateway.LeaseArbiterTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.LeaseArbiter
  alias CrestCiGateway.Test.FakeKubeClient

  @gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  # `raw_conn` is the FakeKubeClient Agent pid; `kube_conn` is the
  # `{client_module, raw_conn}` pair LeaseArbiter (and every other
  # KubeClient caller in this project) expects as its `conn` argument.
  defp start_raw_conn do
    {:ok, raw_conn} = FakeKubeClient.start_link()
    raw_conn
  end

  defp kube_conn(raw_conn), do: {FakeKubeClient, raw_conn}

  defp create_queued_job(raw_conn, name) do
    object = %{
      "metadata" => %{"name" => name},
      "status" => %{
        "phase" => "Queued",
        "leasedBy" => "",
        "leaseExpiresAt" => "",
        "acquiredAt" => "",
        "result" => ""
      }
    }

    {:ok, created} = FakeKubeClient.create(raw_conn, @gvk, @namespace, object)
    created
  end

  defp fetch_status(raw_conn, name) do
    {:ok, object} = FakeKubeClient.get(raw_conn, @gvk, @namespace, name)
    object["status"]
  end

  describe "lease/4" do
    test "leases a Queued RunnerJob, moving it to Leased with leasedBy set" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-1-j-build")

      assert {:ok, :leased} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-1-j-build", "runner-a", 30)

      status = fetch_status(raw_conn, "run-1-j-build")
      assert status["phase"] == "Leased"
      assert status["leasedBy"] == "runner-a"
      assert status["leaseExpiresAt"] != ""
    end

    test "returns {:error, :not_found} for a RunnerJob that does not exist" do
      raw_conn = start_raw_conn()

      assert {:error, :not_found} =
               LeaseArbiter.lease(kube_conn(raw_conn), "does-not-exist", "runner-a", 30)
    end

    test "returns {:error, :lost} when the job is already Leased" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-2-j-build")

      assert {:ok, :leased} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-2-j-build", "runner-a", 30)

      assert {:error, :lost} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-2-j-build", "runner-b", 30)

      # leasedBy still reflects the original (only) winner, never the loser.
      status = fetch_status(raw_conn, "run-2-j-build")
      assert status["leasedBy"] == "runner-a"
    end

    test "returns {:error, :lost} when the job is already Acquired" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-3-j-build")

      assert {:ok, :leased} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-3-j-build", "runner-a", 30)

      assert {:ok, :acquired} =
               LeaseArbiter.confirm_acquisition(kube_conn(raw_conn), "run-3-j-build", "runner-a")

      assert {:error, :lost} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-3-j-build", "runner-b", 30)
    end

    test "exactly one winner among N concurrent acquirers racing the same Queued RunnerJob" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-4-j-build")
      conn = kube_conn(raw_conn)

      runners = for i <- 1..12, do: "runner-#{i}"

      results =
        runners
        |> Enum.map(fn runner ->
          Task.async(fn -> {runner, LeaseArbiter.lease(conn, "run-4-j-build", runner, 30)} end)
        end)
        |> Enum.map(&Task.await/1)

      winners = for {runner, {:ok, :leased}} <- results, do: runner
      losers = for {_runner, result} <- results, result != {:ok, :leased}, do: result

      assert length(winners) == 1
      assert length(losers) == length(runners) - 1
      assert Enum.all?(losers, &(&1 == {:error, :lost}))

      [winner] = winners
      status = fetch_status(raw_conn, "run-4-j-build")
      assert status["leasedBy"] == winner
      assert status["phase"] == "Leased"
    end
  end

  describe "confirm_acquisition/3" do
    test "confirms acquisition for the runner holding the lease, moving Leased -> Acquired" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-5-j-build")
      conn = kube_conn(raw_conn)

      assert {:ok, :leased} = LeaseArbiter.lease(conn, "run-5-j-build", "runner-a", 30)

      assert {:ok, :acquired} =
               LeaseArbiter.confirm_acquisition(conn, "run-5-j-build", "runner-a")

      status = fetch_status(raw_conn, "run-5-j-build")
      assert status["phase"] == "Acquired"
      assert status["leasedBy"] == "runner-a"
      assert status["acquiredAt"] != ""
    end

    test "returns {:error, :lost} when leased_by does not match the recorded lease holder" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-6-j-build")
      conn = kube_conn(raw_conn)

      assert {:ok, :leased} = LeaseArbiter.lease(conn, "run-6-j-build", "runner-a", 30)

      assert {:error, :lost} =
               LeaseArbiter.confirm_acquisition(conn, "run-6-j-build", "runner-b")

      status = fetch_status(raw_conn, "run-6-j-build")
      assert status["phase"] == "Leased"
    end

    test "returns {:error, :lost} when the job was never leased (still Queued)" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-7-j-build")

      assert {:error, :lost} =
               LeaseArbiter.confirm_acquisition(kube_conn(raw_conn), "run-7-j-build", "runner-a")
    end

    test "returns {:error, :not_found} for a RunnerJob that does not exist" do
      raw_conn = start_raw_conn()

      assert {:error, :not_found} =
               LeaseArbiter.confirm_acquisition(kube_conn(raw_conn), "does-not-exist", "runner-a")
    end

    test "only one winner among concurrent confirm_acquisition calls for the same lease holder" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-8-j-build")
      conn = kube_conn(raw_conn)

      assert {:ok, :leased} = LeaseArbiter.lease(conn, "run-8-j-build", "runner-a", 30)

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            LeaseArbiter.confirm_acquisition(conn, "run-8-j-build", "runner-a")
          end)
        end)
        |> Enum.map(&Task.await/1)

      winners = Enum.filter(results, &(&1 == {:ok, :acquired}))
      losers = Enum.filter(results, &(&1 == {:error, :lost}))

      assert length(winners) == 1
      assert length(losers) == length(results) - 1

      status = fetch_status(raw_conn, "run-8-j-build")
      assert status["phase"] == "Acquired"
      assert status["leasedBy"] == "runner-a"
    end
  end
end
