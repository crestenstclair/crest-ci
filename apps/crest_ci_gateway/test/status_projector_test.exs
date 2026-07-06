defmodule CrestCiGateway.StatusProjectorTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.JobStatus
  alias CrestCiContract.WorkflowRunStatus
  alias CrestCiGateway.StatusProjector
  alias CrestCiGateway.Test.FakeKubeClient

  @gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  setup do
    {:ok, pid} = FakeKubeClient.start_link()
    conn = {FakeKubeClient, pid}

    object = %{
      "metadata" => %{"name" => "run-1", "namespace" => @namespace},
      "spec" => %{},
      "status" => WorkflowRunStatus.to_wire(WorkflowRunStatus.new())
    }

    {:ok, created} = FakeKubeClient.create(pid, @gvk, @namespace, object)

    %{conn: conn, pid: pid, workflow_run: created}
  end

  test "projects progress onto a job with no prior status record", %{
    conn: conn,
    workflow_run: workflow_run
  } do
    assert {:ok, patched} =
             StatusProjector.project(conn, workflow_run, "build", %{
               phase: :assigned,
               assigned_runner: "runner-1"
             })

    assert {:ok, status} = WorkflowRunStatus.from_wire(patched["status"])
    assert %JobStatus{phase: :assigned, assigned_runner: "runner-1"} = status.jobs["build"]
  end

  test "merges progress on top of an existing job status rather than replacing it", %{
    conn: conn,
    workflow_run: workflow_run
  } do
    {:ok, after_assign} =
      StatusProjector.project(conn, workflow_run, "build", %{
        phase: :assigned,
        assigned_runner: "runner-1"
      })

    assert {:ok, patched} =
             StatusProjector.project(conn, after_assign, "build", %{
               phase: :running,
               started_at: "2026-01-01T00:00:00Z"
             })

    {:ok, status} = WorkflowRunStatus.from_wire(patched["status"])
    job_status = status.jobs["build"]

    assert job_status.phase == :running
    assert job_status.assigned_runner == "runner-1"
    assert job_status.started_at == "2026-01-01T00:00:00Z"
  end

  test "log_chunks never regresses when a stale chunk count is resent", %{
    conn: conn,
    workflow_run: workflow_run
  } do
    {:ok, after_first} =
      StatusProjector.project(conn, workflow_run, "build", %{phase: :running, log_chunks: 5})

    assert {:ok, patched} =
             StatusProjector.project(conn, after_first, "build", %{
               phase: :running,
               log_chunks: 2
             })

    {:ok, status} = WorkflowRunStatus.from_wire(patched["status"])
    assert status.jobs["build"].log_chunks == 5
  end

  test "does not clobber other jobs' status entries", %{conn: conn, workflow_run: workflow_run} do
    {:ok, after_build} =
      StatusProjector.project(conn, workflow_run, "build", %{phase: :running})

    assert {:ok, patched} =
             StatusProjector.project(conn, after_build, "test", %{phase: :assigned})

    {:ok, status} = WorkflowRunStatus.from_wire(patched["status"])
    assert status.jobs["build"].phase == :running
    assert status.jobs["test"].phase == :assigned
  end

  test "on a resourceVersion conflict, rereads current state and retries rather than forcing the write",
       %{conn: conn, pid: pid, workflow_run: workflow_run} do
    # Simulate another writer (controller, or a sibling gateway replica)
    # advancing the resourceVersion behind this caller's back before the
    # patch is attempted.
    FakeKubeClient.external_write(pid, @gvk, @namespace, "run-1")

    assert {:ok, patched} =
             StatusProjector.project(conn, workflow_run, "build", %{
               phase: :assigned,
               assigned_runner: "runner-1"
             })

    # The stale resourceVersion the caller started with was never forced
    # onto the store — the final state reflects a successful CAS against
    # the fresh (post-external-write) resourceVersion.
    assert patched["metadata"]["resourceVersion"] != workflow_run["metadata"]["resourceVersion"]

    {:ok, status} = WorkflowRunStatus.from_wire(patched["status"])
    assert status.jobs["build"].phase == :assigned
  end

  test "gives up with {:error, :conflict} rather than forcing a write when conflicts never clear",
       %{workflow_run: workflow_run} do
    {:ok, pid} = FakeKubeClient.start_link()
    {:ok, created} = FakeKubeClient.create(pid, @gvk, @namespace, workflow_run)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    conn = {CrestCiGateway.Test.AlwaysConflictKubeClient, {pid, counter}}

    assert {:error, :conflict} =
             StatusProjector.project(conn, created, "build", %{phase: :assigned})

    # Every attempt hit patch_status; none of them was allowed to force a
    # write through despite exhausting all retries.
    assert Agent.get(counter, & &1) > 1

    {:ok, current} = FakeKubeClient.get(pid, @gvk, @namespace, "run-1")
    assert current["metadata"]["resourceVersion"] == created["metadata"]["resourceVersion"]
  end
end
