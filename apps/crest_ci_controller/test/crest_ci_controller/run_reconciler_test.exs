defmodule CrestCiController.RunReconcilerTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{DeterministicNaming, JobStatus, WorkflowRunStatus}
  alias CrestCiController.RunReconciler
  alias CrestCiController.Test.FakeKubeClient

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @pod_gvk {"core", "v1", "Pod"}
  @namespace "default"

  @ulid "run-01ARZ3NDEKTSV4RRFFQ69G5FAV"

  setup do
    {:ok, agent} = FakeKubeClient.start_link()
    {:ok, agent: agent, kube_conn: {FakeKubeClient, agent}}
  end

  defp job!(fields), do: CrestCiContract.PlanJob.new(fields) |> elem(1)

  describe "reconcile/3 — executes ReconcilePlanner's commands via KubeClient" do
    test "creates exactly one RunnerJob and one pod for a runnable job with no needs", %{
      kube_conn: kube_conn
    } do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})]
      }

      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])

      runner_job_name = DeterministicNaming.runner_job_name(@ulid, "build")
      pod_name = DeterministicNaming.pod_name(@ulid, "build")

      {:ok, jobs, _continue} =
        FakeKubeClient.list(elem(kube_conn, 1), @runner_job_gvk, @namespace, [])

      {:ok, pods, _continue} = FakeKubeClient.list(elem(kube_conn, 1), @pod_gvk, @namespace, [])

      assert [runner_job] = jobs
      assert get_in(runner_job, ["metadata", "name"]) == runner_job_name
      assert get_in(runner_job, ["spec", "jobKey"]) == "build"

      assert [pod] = pods
      assert get_in(pod, ["metadata", "name"]) == pod_name
    end

    test "re-reconciling with the RunnerJob already known produces no duplicate create", %{
      kube_conn: kube_conn
    } do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})]
      }

      runner_job_name = DeterministicNaming.runner_job_name(@ulid, "build")

      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])
      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [runner_job_name])

      {:ok, jobs, _continue} =
        FakeKubeClient.list(elem(kube_conn, 1), @runner_job_gvk, @namespace, [])

      assert length(jobs) == 1
    end

    test "creating over an already-existing RunnerJob (409) is tolerated as a no-op", %{
      kube_conn: kube_conn
    } do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})]
      }

      # Existing_runner_jobs deliberately stale (empty) so the planner
      # re-proposes the create command; the KubeClient's own 409 tolerance
      # must absorb it.
      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])
      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])

      {:ok, jobs, _continue} =
        FakeKubeClient.list(elem(kube_conn, 1), @runner_job_gvk, @namespace, [])

      assert length(jobs) == 1
    end

    test "marks jobs skipped when a declared need already failed", %{kube_conn: kube_conn} do
      job_statuses = %{"build" => job_status!(:failed)}

      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})],
        job_statuses: job_statuses,
        namespace: @namespace,
        resource_version: seed_workflow_run!(kube_conn, @ulid, job_statuses, :running)
      }

      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])

      {:ok, run} = FakeKubeClient.get(elem(kube_conn, 1), @workflow_run_gvk, @namespace, @ulid)
      {:ok, status} = WorkflowRunStatus.from_wire(Map.get(run, "status", %{}))

      assert status.jobs["test"].phase == :skipped
    end

    test "aggregates the run phase to a terminal phase once every job is terminal", %{
      kube_conn: kube_conn
    } do
      job_statuses = %{"build" => job_status!(:succeeded)}

      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})],
        job_statuses: job_statuses,
        namespace: @namespace,
        resource_version: seed_workflow_run!(kube_conn, @ulid, job_statuses, :running)
      }

      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])

      {:ok, run} = FakeKubeClient.get(elem(kube_conn, 1), @workflow_run_gvk, @namespace, @ulid)
      {:ok, status} = WorkflowRunStatus.from_wire(Map.get(run, "status", %{}))

      assert status.phase == :succeeded
    end

    test "honors an explicit :namespace key on workflow_run rather than a hardcoded default", %{
      kube_conn: kube_conn
    } do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})],
        namespace: "custom-ns"
      }

      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])

      {:ok, jobs, _continue} =
        FakeKubeClient.list(elem(kube_conn, 1), @runner_job_gvk, "custom-ns", [])

      assert length(jobs) == 1

      {:ok, default_ns_jobs, _continue} =
        FakeKubeClient.list(elem(kube_conn, 1), @runner_job_gvk, @namespace, [])

      assert default_ns_jobs == []
    end

    test "a lost patch_status CAS is tolerated, not forced", %{kube_conn: kube_conn} do
      job_statuses = %{"build" => job_status!(:succeeded)}

      workflow_run = %{
        ulid: @ulid,
        run_ref: @ulid,
        plan: [job!(%{key: "build"})],
        job_statuses: job_statuses,
        namespace: @namespace,
        resource_version: "stale-rv"
      }

      seed_workflow_run!(kube_conn, @ulid, job_statuses, :running)

      # `resource_version: "stale-rv"` above deliberately mismatches
      # whatever the seed call actually stored, so the patch_status
      # command's CAS is guaranteed to lose — reconcile/3 must still
      # return :ok rather than raising or forcing the write.
      assert :ok = RunReconciler.reconcile(kube_conn, workflow_run, [])
    end
  end

  defp job_status!(phase), do: JobStatus.new(%{phase: phase}) |> elem(1)

  defp seed_workflow_run!(kube_conn, name, job_statuses, phase) do
    status = %WorkflowRunStatus{jobs: job_statuses, phase: phase}

    object = %{
      "metadata" => %{"name" => name},
      "spec" => %{},
      "status" => WorkflowRunStatus.to_wire(status)
    }

    {:ok, created} =
      FakeKubeClient.create(elem(kube_conn, 1), @workflow_run_gvk, @namespace, object)

    get_in(created, ["metadata", "resourceVersion"])
  end
end
