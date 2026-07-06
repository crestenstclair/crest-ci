defmodule CrestCiController.PlanFromDefinitionTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{WorkflowRunSpec, WorkflowRunStatus}
  alias CrestCiController.PlanFromDefinition

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

  defp spec!(fields), do: WorkflowRunSpec.new(base_fields(fields)) |> elem(1)

  defp base_fields(fields) do
    Map.merge(%{repo: "octo/example", ref: "refs/heads/main", sha: "deadbeef"}, fields)
  end

  defp plan_job!(fields), do: CrestCiContract.PlanJob.new(fields) |> elem(1)

  describe "resolve_plan/3 — hand-planned runs" do
    test "returns spec.plan unchanged when it is already non-empty, even if workflowYaml is present" do
      hand_plan = [plan_job!(%{key: "build"})]
      spec = spec!(%{plan: hand_plan})
      spec_wire = %{"workflowYaml" => @two_job_yaml}
      status = WorkflowRunStatus.new()

      assert {:ok, :hand_planned, plan} = PlanFromDefinition.resolve_plan(spec, spec_wire, status)
      assert plan == hand_plan
    end
  end

  describe "resolve_plan/3 — already-planned runs" do
    test "returns status.plan unchanged when spec.plan is empty but a plan was already derived" do
      cached_plan = [plan_job!(%{key: "build"})]
      spec = spec!(%{plan: []})
      status = WorkflowRunStatus.put_plan(WorkflowRunStatus.new(), cached_plan)

      assert {:ok, :already_planned, plan} =
               PlanFromDefinition.resolve_plan(spec, %{"workflowYaml" => @two_job_yaml}, status)

      assert plan == cached_plan
    end
  end

  describe "resolve_plan/3 — no plan at all" do
    test "returns an empty plan when there is no hand plan, no cached plan, and no workflowYaml" do
      spec = spec!(%{plan: []})
      status = WorkflowRunStatus.new()

      assert {:ok, :no_plan, []} = PlanFromDefinition.resolve_plan(spec, %{}, status)
    end
  end

  describe "resolve_plan/3 — engine expansion" do
    test "expands workflowYaml into a plan via the Engine pipeline exactly when neither a hand nor cached plan exists" do
      spec = spec!(%{plan: []})
      status = WorkflowRunStatus.new()

      assert {:ok, :freshly_planned, plan} =
               PlanFromDefinition.resolve_plan(spec, %{"workflowYaml" => @two_job_yaml}, status)

      assert Enum.map(plan, & &1.key) |> Enum.sort() == ["build", "lint"]
    end

    test "returns a structured, wrapped PlanError when workflowYaml fails to expand" do
      spec = spec!(%{plan: []})
      status = WorkflowRunStatus.new()

      assert {:error, {:plan_from_definition_failed, {:unknown_needs, offenses}}} =
               PlanFromDefinition.resolve_plan(
                 spec,
                 %{"workflowYaml" => @cyclic_needs_yaml},
                 status
               )

      assert [%{job_id: "build", target: "missing"}] = offenses
    end
  end
end
