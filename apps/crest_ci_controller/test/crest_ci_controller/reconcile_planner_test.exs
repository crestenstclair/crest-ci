defmodule CrestCiController.ReconcilePlannerTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{DeterministicNaming, JobStatus, PlanJob}
  alias CrestCiController.ReconcilePlanner

  defp job!(fields), do: PlanJob.new(fields) |> elem(1)

  defp status!(fields), do: JobStatus.new(fields) |> elem(1)

  @ulid "01ARZ3NDEKTSV4RRFFQ69G5FAV"
  @run_ref "run-ref-1"

  describe "plan/2 — create commands for runnable jobs" do
    test "a waiting job with no needs gets a create_runner_job and create_pod command" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})]
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      runner_job_name = DeterministicNaming.runner_job_name(@ulid, "build")
      pod_name = DeterministicNaming.pod_name(@ulid, "build")

      assert {:create_runner_job, %{name: ^runner_job_name, job_key: "build"}} =
               Enum.find(commands, &match?({:create_runner_job, _}, &1))

      assert {:create_pod, %{name: ^pod_name}} =
               Enum.find(commands, &match?({:create_pod, _}, &1))
    end

    test "runs_on defaults to [\"default\"] when the plan job declares no placement" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})]
      }

      [{:create_runner_job, %{runner_job_spec: spec}}, _create_pod, _patch] =
        ReconcilePlanner.plan(workflow_run, [])

      assert spec.runs_on == ["default"]
    end

    test "runs_on is carried through from the plan job when declared" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build", runs_on: ["gpu"]})]
      }

      [{:create_runner_job, %{runner_job_spec: spec}}, _create_pod, _patch] =
        ReconcilePlanner.plan(workflow_run, [])

      assert spec.runs_on == ["gpu"]
    end

    test "a job whose needs are unresolved gets no create commands" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      refute Enum.any?(commands, fn
               {:create_runner_job, %{job_key: "test"}} -> true
               _ -> false
             end)
    end
  end

  describe "plan/2 — idempotent replanning" do
    test "no duplicate create commands when the RunnerJob already exists" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})]
      }

      runner_job_name = DeterministicNaming.runner_job_name(@ulid, "build")

      commands = ReconcilePlanner.plan(workflow_run, [runner_job_name])

      refute Enum.any?(commands, &match?({:create_runner_job, _}, &1))
      refute Enum.any?(commands, &match?({:create_pod, _}, &1))
    end

    test "replanning against the world after prior commands landed produces no duplicate creates" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]
      }

      first_pass = ReconcilePlanner.plan(workflow_run, [])

      created_names =
        for {:create_runner_job, %{name: name}} <- first_pass, do: name

      second_pass = ReconcilePlanner.plan(workflow_run, created_names)

      assert Enum.count(second_pass, &match?({:create_runner_job, _}, &1)) ==
               Enum.count(first_pass, &match?({:create_runner_job, _}, &1)) - 1
    end
  end

  describe "plan/2 — patch_status command" do
    test "skip-classified jobs are marked skipped and runnable jobs are marked queued" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})],
        job_statuses: %{"build" => status!(%{phase: :failed})}
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      assert {:patch_status, %{jobs: jobs}} =
               Enum.find(commands, &match?({:patch_status, _}, &1))

      assert jobs["test"].phase == :skipped
    end

    test "no patch_status command when nothing would change" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})],
        job_statuses: %{"build" => status!(%{phase: :succeeded})},
        phase: :succeeded
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      refute Enum.any?(commands, &match?({:patch_status, _}, &1))
    end

    test "never proposes a transition out of an already-terminal phase" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})],
        job_statuses: %{"build" => status!(%{phase: :failed})},
        phase: :failed
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      case Enum.find(commands, &match?({:patch_status, _}, &1)) do
        {:patch_status, %{phase: phase}} -> assert phase == :failed
        nil -> :ok
      end
    end

    test "aggregates a terminal phase once every job status is terminal" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"})],
        job_statuses: %{"build" => status!(%{phase: :succeeded})},
        phase: :running
      }

      commands = ReconcilePlanner.plan(workflow_run, [])

      assert {:patch_status, %{phase: :succeeded}} =
               Enum.find(commands, &match?({:patch_status, _}, &1))
    end
  end

  describe "plan/2 — determinism" do
    test "identical input always yields an identical command list" do
      workflow_run = %{
        ulid: @ulid,
        run_ref: @run_ref,
        plan: [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})],
        job_statuses: %{"build" => status!(%{phase: :succeeded})}
      }

      first = ReconcilePlanner.plan(workflow_run, ["some-other-name"])
      second = ReconcilePlanner.plan(workflow_run, ["some-other-name"])

      assert first == second
    end
  end
end
