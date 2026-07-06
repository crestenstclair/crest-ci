defmodule CrestCiController.RunReconcilerPlanFromDefinitionTest do
  @moduledoc """
  End-to-end (through the real `RunReconciler` GenServer tick loop, not
  just `reconcile/3` directly) coverage of
  `applicationService.Controller.PlanFromDefinition`: a `WorkflowRun`
  whose spec carries `workflowYaml` and no hand-built plan gets that YAML
  expanded by the Engine and the result persisted into its status before
  any `RunnerJob`/pod is ever created from it; a `WorkflowRun` whose
  `workflowYaml` fails to expand is marked Failed with the structured
  error recorded and never has a job created from it.
  """

  use ExUnit.Case, async: true

  alias CrestCiContract.WorkflowRunStatus
  alias CrestCiController.{LeaderElector, RunReconciler}
  alias CrestCiController.Test.FakeKubeClient

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  @fast_timings %{lease_duration_seconds: 5, renew_interval_ms: 200, retry_interval_ms: 30}

  @two_job_yaml """
  on: push
  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - run: echo build
    lint:
      runs-on: ubuntu-latest
      steps:
        - run: echo lint
  """

  @cyclic_needs_yaml """
  on: push
  jobs:
    build:
      needs: [missing]
      runs-on: ubuntu-latest
      steps: []
  """

  setup do
    {:ok, agent} = FakeKubeClient.start_link()
    kube_conn = {FakeKubeClient, agent}

    {:ok, elector} = LeaderElector.start_link(kube_conn, "instance-a", @fast_timings)
    :ok = LeaderElector.subscribe(elector, self())
    assert_receive {:leader_acquired, "instance-a"}, 2_000

    {:ok, reconciler} = RunReconciler.start_link(kube_conn, elector, %{poll_interval_ms: 20})

    on_exit(fn ->
      if Process.alive?(reconciler), do: GenServer.stop(reconciler)
      if Process.alive?(elector), do: GenServer.stop(elector)
    end)

    {:ok, agent: agent}
  end

  test "expands a workflowYaml-carrying run with no hand plan into RunnerJobs, persisting the derived plan into status",
       %{agent: agent} do
    seed_run!(agent, "run-yaml-ok", @two_job_yaml)

    wait_until(fn ->
      {:ok, jobs, _continue} = FakeKubeClient.list(agent, @runner_job_gvk, @namespace, [])
      length(jobs) == 2
    end)

    {:ok, run} = FakeKubeClient.get(agent, @workflow_run_gvk, @namespace, "run-yaml-ok")
    {:ok, status} = WorkflowRunStatus.from_wire(Map.get(run, "status", %{}))

    assert Enum.map(status.plan, & &1.key) |> Enum.sort() == ["build", "lint"]
    assert status.plan_error == ""
  end

  test "marks the run Failed with a structured plan error when workflowYaml fails to expand, and creates no job",
       %{agent: agent} do
    seed_run!(agent, "run-yaml-bad", @cyclic_needs_yaml)

    wait_until(fn ->
      {:ok, run} = FakeKubeClient.get(agent, @workflow_run_gvk, @namespace, "run-yaml-bad")
      {:ok, status} = WorkflowRunStatus.from_wire(Map.get(run, "status", %{}))
      status.phase == :failed
    end)

    {:ok, run} = FakeKubeClient.get(agent, @workflow_run_gvk, @namespace, "run-yaml-bad")
    {:ok, status} = WorkflowRunStatus.from_wire(Map.get(run, "status", %{}))
    assert status.plan_error != ""

    {:ok, jobs, _continue} = FakeKubeClient.list(agent, @runner_job_gvk, @namespace, [])
    assert jobs == []
  end

  defp seed_run!(agent, name, workflow_yaml) do
    object = %{
      "metadata" => %{"name" => name},
      "spec" => %{
        "repo" => "octo/example",
        "ref" => "refs/heads/main",
        "sha" => "deadbeef",
        "plan" => [],
        "workflowYaml" => workflow_yaml
      },
      "status" => %{"jobs" => %{}, "phase" => "Pending"}
    }

    {:ok, _created} = FakeKubeClient.create(agent, @workflow_run_gvk, @namespace, object)
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
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
