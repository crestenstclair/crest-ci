defmodule CrestCiController.LeaseSweeperTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{JobStatus, RunnerJobSpec, RunnerJobStatus, WorkflowRunStatus}
  alias CrestCiController.LeaseSweeper
  alias CrestCiController.Test.FakeKubeClient

  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  setup do
    {:ok, conn} = FakeKubeClient.start_link()
    %{kube_conn: {FakeKubeClient, conn}}
  end

  defp past(seconds_ago) do
    DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
  end

  defp future(seconds_from_now) do
    DateTime.utc_now() |> DateTime.add(seconds_from_now, :second) |> DateTime.to_iso8601()
  end

  defp put_runner_job({FakeKubeClient, conn} = _kube_conn, name, status, spec) do
    object = %{
      "metadata" => %{"name" => name},
      "spec" => RunnerJobSpec.to_wire(spec),
      "status" => RunnerJobStatus.to_wire(status)
    }

    {:ok, created} = FakeKubeClient.create(conn, @runner_job_gvk, @namespace, object)
    created
  end

  defp put_workflow_run({FakeKubeClient, conn}, name, run_status) do
    object = %{
      "metadata" => %{"name" => name},
      "spec" => %{},
      "status" => WorkflowRunStatus.to_wire(run_status)
    }

    {:ok, created} = FakeKubeClient.create(conn, @workflow_run_gvk, @namespace, object)
    created
  end

  defp fetch_runner_job({FakeKubeClient, conn}, name) do
    {:ok, object} = FakeKubeClient.get(conn, @runner_job_gvk, @namespace, name)
    {:ok, status} = RunnerJobStatus.from_wire(object["status"])
    status
  end

  defp fetch_workflow_run_status({FakeKubeClient, conn}, name) do
    {:ok, object} = FakeKubeClient.get(conn, @workflow_run_gvk, @namespace, name)
    {:ok, status} = WorkflowRunStatus.from_wire(object["status"])
    status
  end

  defp runner_job_spec(run_ref, job_key) do
    {:ok, spec} =
      RunnerJobSpec.new(%{
        job_key: job_key,
        run_ref: run_ref,
        runs_on: ["default"],
        job_message: %{}
      })

    spec
  end

  test "reverts a Leased-but-unacquired RunnerJob past leaseExpiresAt back to Queued", %{
    kube_conn: kube_conn
  } do
    {:ok, status} =
      RunnerJobStatus.new(%{
        phase: :leased,
        leased_by: "runner-1",
        lease_expires_at: past(30)
      })

    put_runner_job(kube_conn, "run-1-j-build", status, runner_job_spec("run-1", "build"))

    assert :ok = LeaseSweeper.sweep(kube_conn)

    reverted = fetch_runner_job(kube_conn, "run-1-j-build")
    assert reverted.phase == :queued
    assert reverted.leased_by == ""
    assert reverted.lease_expires_at == ""
  end

  test "leaves a Leased RunnerJob alone while its lease has not yet expired", %{
    kube_conn: kube_conn
  } do
    {:ok, status} =
      RunnerJobStatus.new(%{
        phase: :leased,
        leased_by: "runner-1",
        lease_expires_at: future(30)
      })

    put_runner_job(kube_conn, "run-2-j-build", status, runner_job_spec("run-2", "build"))

    assert :ok = LeaseSweeper.sweep(kube_conn)

    unchanged = fetch_runner_job(kube_conn, "run-2-j-build")
    assert unchanged.phase == :leased
    assert unchanged.leased_by == "runner-1"
  end

  test "abandons an Acquired RunnerJob whose lease heartbeat lapsed and fails the owning WorkflowRun job",
       %{kube_conn: kube_conn} do
    {:ok, status} =
      RunnerJobStatus.new(%{
        phase: :acquired,
        leased_by: "runner-9",
        acquired_at: past(60),
        lease_expires_at: past(10)
      })

    put_runner_job(kube_conn, "run-3-j-test", status, runner_job_spec("run-3", "test"))

    {:ok, job_status} = JobStatus.new(%{phase: :running, assigned_runner: "runner-9"})
    run_status = WorkflowRunStatus.new(%{"test" => job_status})
    put_workflow_run(kube_conn, "run-3", run_status)

    assert :ok = LeaseSweeper.sweep(kube_conn)

    abandoned = fetch_runner_job(kube_conn, "run-3-j-test")
    assert abandoned.phase == :abandoned
    # audit trail is preserved, only the phase changed
    assert abandoned.leased_by == "runner-9"

    updated_run_status = fetch_workflow_run_status(kube_conn, "run-3")
    assert updated_run_status.jobs["test"].phase == :failed
    assert updated_run_status.phase == :failed
  end

  test "leaves an Acquired RunnerJob alone while its lease has not yet expired", %{
    kube_conn: kube_conn
  } do
    {:ok, status} =
      RunnerJobStatus.new(%{
        phase: :acquired,
        leased_by: "runner-9",
        acquired_at: past(5),
        lease_expires_at: future(30)
      })

    put_runner_job(kube_conn, "run-4-j-test", status, runner_job_spec("run-4", "test"))

    assert :ok = LeaseSweeper.sweep(kube_conn)

    unchanged = fetch_runner_job(kube_conn, "run-4-j-test")
    assert unchanged.phase == :acquired
  end

  test "never touches Queued, Completed, or Abandoned RunnerJobs regardless of leaseExpiresAt", %{
    kube_conn: kube_conn
  } do
    {:ok, queued} = RunnerJobStatus.new(%{phase: :queued, lease_expires_at: past(60)})
    {:ok, completed} = RunnerJobStatus.new(%{phase: :completed, lease_expires_at: past(60)})
    {:ok, abandoned} = RunnerJobStatus.new(%{phase: :abandoned, lease_expires_at: past(60)})

    put_runner_job(kube_conn, "run-5-j-a", queued, runner_job_spec("run-5", "a"))
    put_runner_job(kube_conn, "run-5-j-b", completed, runner_job_spec("run-5", "b"))
    put_runner_job(kube_conn, "run-5-j-c", abandoned, runner_job_spec("run-5", "c"))

    assert :ok = LeaseSweeper.sweep(kube_conn)

    assert fetch_runner_job(kube_conn, "run-5-j-a").phase == :queued
    assert fetch_runner_job(kube_conn, "run-5-j-b").phase == :completed
    assert fetch_runner_job(kube_conn, "run-5-j-c").phase == :abandoned
  end

  test "sweep is idempotent: running it twice on the same expired lease converges without error",
       %{kube_conn: kube_conn} do
    {:ok, status} =
      RunnerJobStatus.new(%{phase: :leased, leased_by: "runner-1", lease_expires_at: past(30)})

    put_runner_job(kube_conn, "run-6-j-build", status, runner_job_spec("run-6", "build"))

    assert :ok = LeaseSweeper.sweep(kube_conn)
    assert :ok = LeaseSweeper.sweep(kube_conn)

    final = fetch_runner_job(kube_conn, "run-6-j-build")
    assert final.phase == :queued
  end

  test "a missing owning WorkflowRun does not prevent the RunnerJob from being abandoned", %{
    kube_conn: kube_conn
  } do
    {:ok, status} =
      RunnerJobStatus.new(%{
        phase: :acquired,
        leased_by: "runner-9",
        lease_expires_at: past(10)
      })

    put_runner_job(kube_conn, "run-7-j-test", status, runner_job_spec("run-7", "test"))

    assert :ok = LeaseSweeper.sweep(kube_conn)

    abandoned = fetch_runner_job(kube_conn, "run-7-j-test")
    assert abandoned.phase == :abandoned
  end

  test "sweep with no RunnerJobs at all is a no-op that returns :ok", %{kube_conn: kube_conn} do
    assert :ok = LeaseSweeper.sweep(kube_conn)
  end
end
