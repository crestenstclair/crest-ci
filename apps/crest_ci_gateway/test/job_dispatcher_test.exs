defmodule CrestCiGateway.JobDispatcherTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.JobDispatcher
  alias CrestCiGateway.JobDispatcher.Deps
  alias CrestCiGateway.LeaseArbiter
  alias CrestCiGateway.Test.FakeKubeClient

  @gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  defp start_raw_conn do
    {:ok, raw_conn} = FakeKubeClient.start_link()
    raw_conn
  end

  defp kube_conn(raw_conn), do: {FakeKubeClient, raw_conn}

  defp create_queued_job(raw_conn, name, runs_on, job_message \\ %{"steps" => ["build"]}) do
    object = %{
      "metadata" => %{"name" => name},
      "spec" => %{
        "jobKey" => name,
        "jobMessage" => job_message,
        "runRef" => "run-1",
        "runsOn" => runs_on
      },
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

  defp base_deps(raw_conn, overrides \\ %{}) do
    defaults = %{
      kube_conn: kube_conn(raw_conn),
      lease: &LeaseArbiter.lease/4,
      leased_by: "runner-a",
      lease_duration_seconds: 30
    }

    struct!(Deps, Map.merge(defaults, overrides))
  end

  describe "poll/3 — poll arrival when jobs already wait" do
    test "answers immediately with the job_message when a matching Queued RunnerJob exists" do
      raw_conn = start_raw_conn()

      create_queued_job(raw_conn, "run-1-j-build", ["gpu"], %{"steps" => ["compile", "test"]})

      deps = base_deps(raw_conn)

      started = System.monotonic_time(:millisecond)
      assert {:ok, job_message} = JobDispatcher.poll(deps, ["gpu"], 2_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert job_message == %{"steps" => ["compile", "test"]}
      # Won on the immediate scan — no need to wait anywhere near the deadline.
      assert elapsed < 500

      status = fetch_status(raw_conn, "run-1-j-build")
      assert status["phase"] == "Leased"
      assert status["leasedBy"] == "runner-a"
    end

    test "does not match a Queued RunnerJob whose runsOn set differs" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-2-j-build", ["arm"])

      deps = base_deps(raw_conn)

      assert :timeout = JobDispatcher.poll(deps, ["gpu"], 150)

      status = fetch_status(raw_conn, "run-2-j-build")
      assert status["phase"] == "Queued"
    end

    test "does not match a RunnerJob that is not Queued" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-3-j-build", ["gpu"])

      deps = base_deps(raw_conn)

      assert {:ok, :leased} =
               LeaseArbiter.lease(kube_conn(raw_conn), "run-3-j-build", "runner-z", 30)

      assert :timeout = JobDispatcher.poll(deps, ["gpu"], 150)
    end

    test "matches runsOn as a set, independent of declared order" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-4-j-build", ["gpu", "linux"])

      deps = base_deps(raw_conn)

      assert {:ok, _job_message} = JobDispatcher.poll(deps, ["linux", "gpu"], 2_000)
    end
  end

  describe "poll/3 — deadline and timeout" do
    test "returns :timeout once deadline_ms elapses with no matching job" do
      raw_conn = start_raw_conn()
      deps = base_deps(raw_conn)

      started = System.monotonic_time(:millisecond)
      assert :timeout = JobDispatcher.poll(deps, ["gpu"], 150)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 150
      assert elapsed < 1_000
    end
  end

  describe "poll/3 — level-triggered wake on a later change" do
    test "picks up a RunnerJob created after the poll has already started, before the deadline" do
      raw_conn = start_raw_conn()
      test_pid = self()

      deps =
        base_deps(raw_conn, %{
          list_notifier: fn -> send(test_pid, :crest_ci_test_scanned) end
        })

      task = Task.async(fn -> JobDispatcher.poll(deps, ["gpu"], 5_000) end)

      # Wait for the observable fact that the dispatcher has performed at
      # least its initial scan (found nothing) before creating the job —
      # no sleep, just message-passing synchronization.
      assert_receive :crest_ci_test_scanned, 1_000

      create_queued_job(raw_conn, "run-5-j-build", ["gpu"], %{"steps" => ["deploy"]})

      assert {:ok, job_message} = Task.await(task, 2_000)
      assert job_message == %{"steps" => ["deploy"]}
    end
  end

  describe "poll/3 — single-winner arbitration" do
    test "exactly one of N concurrent pollers wins the single matching Queued RunnerJob" do
      raw_conn = start_raw_conn()
      create_queued_job(raw_conn, "run-6-j-build", ["gpu"], %{"steps" => ["build"]})

      results =
        1..8
        |> Enum.map(fn i ->
          deps = base_deps(raw_conn, %{leased_by: "runner-#{i}"})
          Task.async(fn -> JobDispatcher.poll(deps, ["gpu"], 300) end)
        end)
        |> Enum.map(&Task.await(&1, 2_000))

      winners = for {:ok, job_message} <- results, do: job_message
      losers = for :timeout <- results, do: :timeout

      assert length(winners) == 1
      assert length(losers) == length(results) - 1
      assert hd(winners) == %{"steps" => ["build"]}

      status = fetch_status(raw_conn, "run-6-j-build")
      assert status["phase"] == "Leased"
    end
  end
end
