defmodule SimRunner.Scene.StateSnapshotterTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.{Snapshot, StateSnapshotter}

  defmodule FakeKubeClient do
    @moduledoc false
    # Minimal test-only `CrestCiContract.KubeClient` double, scoped to this
    # test module. Only `list/4` is exercised by `StateSnapshotter.take/3`;
    # every other callback is unused here and simply not implemented.
    @behaviour CrestCiContract.KubeClient

    @impl true
    def list(conn, gvk, _namespace, opts) do
      Agent.get(conn, fn state ->
        continue = Keyword.get(opts, :continue)
        pages = Map.get(state, gvk, [[]])
        index = if continue, do: continue, else: 0
        page = Enum.at(pages, index, [])
        next = if index + 1 < length(pages), do: index + 1, else: nil
        {:ok, page, next}
      end)
    end

    @impl true
    def get(_conn, _gvk, _namespace, _name), do: {:error, :not_found}

    @impl true
    def create(_conn, _gvk, _namespace, _object), do: {:error, :unimplemented}

    @impl true
    def update(_conn, _gvk, _namespace, _object), do: {:error, :unimplemented}

    @impl true
    def patch_status(_conn, _gvk, _namespace, _name, _status, _rv), do: {:error, :unimplemented}

    @impl true
    def delete(_conn, _gvk, _namespace, _name), do: {:error, :unimplemented}

    @impl true
    def watch(_conn, _gvk, _namespace, _from_rv, _callback), do: {:error, :unimplemented}
  end

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @lease_gvk {"coordination.k8s.io", "v1", "Lease"}
  @pod_gvk {"core", "v1", "Pod"}

  defp workflow_run(name, phase, jobs \\ %{}) do
    %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => name},
      "status" => %{"phase" => phase, "jobs" => jobs}
    }
  end

  defp job_status_wire(phase, opts \\ []) do
    %{
      "phase" => phase,
      "logChunks" => Keyword.get(opts, :log_chunks, 0),
      "outputs" => Keyword.get(opts, :outputs, %{}),
      "assignedRunner" => "",
      "queuedAt" => "",
      "startedAt" => "",
      "finishedAt" => ""
    }
  end

  defp runner_job(name, phase, acquisition_count \\ 0) do
    %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "RunnerJob",
      "metadata" => %{"name" => name},
      "status" => %{
        "phase" => phase,
        "leasedBy" => "",
        "leaseExpiresAt" => "",
        "acquiredAt" => "",
        "result" => "",
        "acquisitionCount" => acquisition_count
      }
    }
  end

  defp lease(name, holder_identity, renew_time, lease_duration_seconds, lease_transitions \\ 0) do
    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{"name" => name},
      "spec" => %{
        "holderIdentity" => holder_identity,
        "acquireTime" => renew_time,
        "renewTime" => renew_time,
        "leaseDurationSeconds" => lease_duration_seconds,
        "leaseTransitions" => lease_transitions
      }
    }
  end

  defp pod(name, opts) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => name,
        "labels" => Keyword.get(opts, :labels, %{})
      },
      "status" => %{"phase" => Keyword.get(opts, :phase, "Running")}
    }
  end

  describe "from_resources/6 — empty inputs" do
    test "yields an all-zero Snapshot with elapsed_ms passed through" do
      assert {:ok, snapshot} = StateSnapshotter.from_resources([], [], [], [], 1500)

      assert snapshot == %Snapshot{
               acquisitions: 0,
               cache_hits: 0,
               cache_misses: 0,
               chunk_count: 0,
               done: 0,
               duplicate_acquisitions: 0,
               elapsed_ms: 1500,
               failovers: [],
               gateways: [],
               leader: "",
               lease_remaining_s: 0,
               leased: 0,
               queued: 0,
               running: 0,
               runs: []
             }
    end
  end

  describe "from_resources/6 — WorkflowRuns" do
    test "counts only terminal phases toward done, and projects the runs list" do
      jobs = %{
        "build" => job_status_wire("Succeeded"),
        "test" => job_status_wire("Running")
      }

      running_jobs = %{"deploy" => job_status_wire("Running")}

      runs = [
        workflow_run("run-a", "Succeeded", jobs),
        # Non-terminal wire phases are recomputed from `jobs` by
        # `WorkflowRunStatus.from_wire/1` (phase is always a pure
        # derivation of `jobs` — see its moduledoc), so a "Failed"/
        # "Cancelled" wire phase with no matching terminal job state would
        # NOT stick; only genuinely terminal phases (which `from_wire/1`
        # preserves as-is) exercise the `done` count here.
        workflow_run("run-b", "Failed"),
        workflow_run("run-c", "Cancelled"),
        workflow_run("run-d", "Running", running_jobs),
        workflow_run("run-e", "Pending")
      ]

      assert {:ok, snapshot} = StateSnapshotter.from_resources(runs, [], [], [], 0)

      assert snapshot.done == 3

      assert %{"name" => "run-a", "phase" => "Succeeded", "jobsTotal" => 2, "jobsDone" => 1} =
               Enum.find(snapshot.runs, &(&1["name"] == "run-a"))

      assert %{"name" => "run-d", "phase" => "Running", "jobsTotal" => 1, "jobsDone" => 0} =
               Enum.find(snapshot.runs, &(&1["name"] == "run-d"))

      assert length(snapshot.runs) == 5
    end

    test "an undecodable status is treated as Pending with no jobs, not a crash" do
      runs = [
        %{"metadata" => %{"name" => "broken"}, "status" => %{"phase" => "NotARealPhase"}}
      ]

      assert {:ok, snapshot} = StateSnapshotter.from_resources(runs, [], [], [], 0)
      assert snapshot.done == 0

      assert [%{"name" => "broken", "phase" => "Pending", "jobsTotal" => 0, "jobsDone" => 0}] =
               snapshot.runs
    end
  end

  describe "from_resources/6 — RunnerJobs" do
    test "buckets queued/leased/acquired into queued/leased/running" do
      jobs = [
        runner_job("j1", "Queued"),
        runner_job("j2", "Queued"),
        runner_job("j3", "Leased"),
        runner_job("j4", "Acquired"),
        runner_job("j5", "Completed"),
        runner_job("j6", "Abandoned")
      ]

      assert {:ok, snapshot} = StateSnapshotter.from_resources([], jobs, [], [], 0)

      assert snapshot.queued == 2
      assert snapshot.leased == 1
      assert snapshot.running == 1
    end

    test "acquisitions is the sum of acquisitionCount and duplicates is sum(max(count-1,0))" do
      jobs = [
        runner_job("j1", "Acquired", 1),
        runner_job("j2", "Acquired", 3),
        runner_job("j3", "Completed", 2),
        runner_job("j4", "Queued", 0)
      ]

      assert {:ok, snapshot} = StateSnapshotter.from_resources([], jobs, [], [], 0)

      # sum(1, 3, 2, 0) = 6
      assert snapshot.acquisitions == 6
      # max(1-1,0) + max(3-1,0) + max(2-1,0) + max(0-1,0) = 0 + 2 + 1 + 0 = 3
      assert snapshot.duplicate_acquisitions == 3
    end
  end

  describe "from_resources/6 — log chunks and cache outcomes" do
    test "sums logChunks and counts cacheResult hit/miss outputs across every run's jobs" do
      jobs = %{
        "build" =>
          job_status_wire("Succeeded", log_chunks: 5, outputs: %{"cacheResult" => "hit"}),
        "test" =>
          job_status_wire("Succeeded", log_chunks: 3, outputs: %{"cacheResult" => "miss"}),
        "lint" => job_status_wire("Succeeded", log_chunks: 2, outputs: %{})
      }

      runs = [workflow_run("run-a", "Succeeded", jobs)]

      assert {:ok, snapshot} = StateSnapshotter.from_resources(runs, [], [], [], 0)

      assert snapshot.chunk_count == 10
      assert snapshot.cache_hits == 1
      assert snapshot.cache_misses == 1
    end
  end

  describe "from_resources/6 — Lease" do
    test "a healthy lease yields its holder and a positive remaining seconds" do
      now = ~U[2026-01-01 00:00:10Z]
      renew_time = "2026-01-01T00:00:00Z"

      leases = [lease("crest-ci-controller", "controller-0", renew_time, 30)]

      assert {:ok, snapshot} =
               StateSnapshotter.from_resources([], [], leases, [], 0, now: now)

      assert snapshot.leader == "controller-0"
      # expiry = 00:00:30, now = 00:00:10 -> 20s remaining
      assert snapshot.lease_remaining_s == 20
    end

    test "an expired lease yields a negative remaining seconds without erroring" do
      now = ~U[2026-01-01 00:01:00Z]
      renew_time = "2026-01-01T00:00:00Z"

      leases = [lease("crest-ci-controller", "controller-0", renew_time, 30)]

      assert {:ok, snapshot} =
               StateSnapshotter.from_resources([], [], leases, [], 0, now: now)

      assert snapshot.leader == "controller-0"
      assert snapshot.lease_remaining_s == -30
    end

    test "no matching lease yields an empty leader and zero remaining seconds" do
      leases = [lease("some-other-lease", "controller-0", "2026-01-01T00:00:00Z", 30)]

      assert {:ok, snapshot} = StateSnapshotter.from_resources([], [], leases, [], 0)

      assert snapshot.leader == ""
      assert snapshot.lease_remaining_s == 0
    end

    test "a custom :lease_name option selects a different Lease object" do
      leases = [
        lease("crest-ci-controller", "controller-0", "2026-01-01T00:00:00Z", 30),
        lease("custom-lease", "controller-1", "2026-01-01T00:00:00Z", 60)
      ]

      assert {:ok, snapshot} =
               StateSnapshotter.from_resources([], [], leases, [], 0, lease_name: "custom-lease")

      assert snapshot.leader == "controller-1"
    end
  end

  describe "from_resources/6 — Pods / gateways" do
    test "only pods labeled crest.dev/component=gateway are projected as gateways" do
      pods = [
        pod("gateway-0", labels: %{"crest.dev/component" => "gateway"}, phase: "Running"),
        pod("run-abc-j-build", labels: %{})
      ]

      assert {:ok, snapshot} = StateSnapshotter.from_resources([], [], [], pods, 0)

      assert snapshot.gateways == [%{"name" => "gateway-0", "phase" => "Running"}]
    end
  end

  describe "from_resources/6 — failovers" do
    test "is always empty — not derivable from a single point-in-time CR listing" do
      assert {:ok, snapshot} = StateSnapshotter.from_resources([], [], [], [], 0)
      assert snapshot.failovers == []
    end
  end

  describe "take/3" do
    setup do
      {:ok, conn} = Agent.start_link(fn -> %{} end)
      {:ok, conn: conn}
    end

    test "lists all four gvks through the injected KubeClient and assembles a Snapshot", %{
      conn: conn
    } do
      Agent.update(conn, fn _state ->
        %{
          @workflow_run_gvk => [[workflow_run("run-a", "Succeeded")]],
          @runner_job_gvk => [[runner_job("j1", "Queued")]],
          @lease_gvk => [
            [lease("crest-ci-controller", "controller-0", "2026-01-01T00:00:00Z", 30)]
          ],
          @pod_gvk => [[pod("gateway-0", labels: %{"crest.dev/component" => "gateway"})]]
        }
      end)

      assert {:ok, snapshot} =
               StateSnapshotter.take({FakeKubeClient, conn}, 42, now: ~U[2026-01-01 00:00:05Z])

      assert snapshot.done == 1
      assert snapshot.queued == 1
      assert snapshot.leader == "controller-0"
      assert snapshot.elapsed_ms == 42
      assert snapshot.gateways == [%{"name" => "gateway-0", "phase" => "Running"}]
    end

    test "follows a multi-page list/4 continuation to completion", %{conn: conn} do
      Agent.update(conn, fn _state ->
        %{
          @workflow_run_gvk => [
            [workflow_run("run-a", "Succeeded")],
            [workflow_run("run-b", "Failed")]
          ],
          @runner_job_gvk => [[]],
          @lease_gvk => [[]],
          @pod_gvk => [[]]
        }
      end)

      assert {:ok, snapshot} = StateSnapshotter.take({FakeKubeClient, conn}, 0)

      assert snapshot.done == 2
      assert length(snapshot.runs) == 2
    end
  end
end
