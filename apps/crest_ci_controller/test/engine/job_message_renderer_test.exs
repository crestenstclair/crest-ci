defmodule CrestCiController.Engine.JobMessageRendererTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.GithubContext
  alias CrestCiController.Engine.JobMessageRenderer
  alias CrestCiContract.JobStatus
  alias CrestCiContract.PlanJob

  defp github_context(overrides \\ %{}) do
    fields =
      Map.merge(
        %{
          actor: "octocat",
          event: %{"foo" => "bar"},
          event_name: "push",
          ref: "refs/heads/main",
          repository: "octo/repo",
          sha: "abc123"
        },
        overrides
      )

    {:ok, context} = GithubContext.new(fields)
    context
  end

  defp job_status(overrides) do
    fields = Map.merge(%{phase: :succeeded}, overrides)
    {:ok, status} = JobStatus.new(fields)
    status
  end

  defp plan_job(overrides) do
    fields =
      Map.merge(
        %{
          key: "build",
          steps: [%{"run" => "echo ${{ github.sha }}"}]
        },
        overrides
      )

    {:ok, plan_job} = PlanJob.new(fields)
    plan_job
  end

  describe "render/2" do
    test "carries steps through unevaluated, byte-for-byte" do
      job =
        plan_job(%{
          steps: [
            %{"run" => "echo ${{ github.sha }}"},
            %{"uses" => "actions/checkout@v4", "with" => %{"ref" => "${{ github.ref }}"}}
          ]
        })

      assert {:ok, message} =
               JobMessageRenderer.render(job, %{github_context: github_context()})

      assert message["steps"] == [
               %{"run" => "echo ${{ github.sha }}"},
               %{"uses" => "actions/checkout@v4", "with" => %{"ref" => "${{ github.ref }}"}}
             ]
    end

    test "env is the job-tier merge from ContextAssembler, job wins on collision" do
      job = plan_job(%{})

      assert {:ok, message} =
               JobMessageRenderer.render(job, %{
                 github_context: github_context(),
                 workflow_env: %{"SHARED" => "workflow", "ONLY_WORKFLOW" => "w"},
                 job_env: %{"SHARED" => "job", "ONLY_JOB" => "j"}
               })

      assert message["env"] == %{
               "SHARED" => "job",
               "ONLY_WORKFLOW" => "w",
               "ONLY_JOB" => "j"
             }
    end

    test "needs is the outputs snapshot for every satisfied dependency" do
      job = plan_job(%{key: "deploy", needs: ["build"]})

      status = job_status(%{phase: :succeeded, outputs: %{"artifact" => "build-42"}})

      assert {:ok, message} =
               JobMessageRenderer.render(job, %{
                 github_context: github_context(),
                 needs: ["build"],
                 job_statuses: %{"build" => status}
               })

      assert message["needs"] == %{
               "build" => %{"result" => "success", "outputs" => %{"artifact" => "build-42"}}
             }
    end

    test "no declared needs renders an empty needs snapshot and default env" do
      job = plan_job(%{})

      assert {:ok, message} =
               JobMessageRenderer.render(job, %{github_context: github_context()})

      assert message["needs"] == %{}
      assert message["env"] == %{}
    end

    test "rendered message has exactly the steps/env/needs branches" do
      job = plan_job(%{})

      assert {:ok, message} =
               JobMessageRenderer.render(job, %{github_context: github_context()})

      assert Map.keys(message) |> Enum.sort() == ["env", "needs", "steps"]
    end

    test "propagates a missing needs dependency as the ContextAssembler error, unchanged" do
      job = plan_job(%{key: "deploy", needs: ["build"]})

      assert {:error, {:missing_need_status, "build"}} =
               JobMessageRenderer.render(job, %{
                 github_context: github_context(),
                 needs: ["build"]
               })
    end

    test "propagates an unsatisfied (non-terminal) needs dependency as an error" do
      job = plan_job(%{key: "deploy", needs: ["build"]})
      status = job_status(%{phase: :running})

      assert {:error, {:unsatisfied_need, "build", :running}} =
               JobMessageRenderer.render(job, %{
                 github_context: github_context(),
                 needs: ["build"],
                 job_statuses: %{"build" => status}
               })
    end

    test "propagates a malformed context field as the ContextAssembler error" do
      job = plan_job(%{})

      assert {:error, {:invalid_workflow_env, "not-a-map"}} =
               JobMessageRenderer.render(job, %{
                 github_context: github_context(),
                 workflow_env: "not-a-map"
               })
    end

    test "rejects a plan_job that is not a PlanJob struct" do
      assert {:error, {:invalid_plan_job, %{}}} =
               JobMessageRenderer.render(%{}, %{github_context: github_context()})
    end

    test "rejects context_fields that is not a map" do
      job = plan_job(%{})

      assert {:error, {:invalid_context_fields, "nope"}} =
               JobMessageRenderer.render(job, "nope")
    end

    test "deterministic: identical inputs render a byte-identical encoded message" do
      job =
        plan_job(%{
          key: "deploy",
          needs: ["build", "lint"],
          runs_on: ["linux", "gpu"],
          steps: [%{"run" => "echo ${{ needs.build.outputs.artifact }}"}]
        })

      context_fields = %{
        github_context: github_context(),
        workflow_env: %{"A" => "1", "B" => "2"},
        job_env: %{"C" => "3"},
        needs: ["build", "lint"],
        job_statuses: %{
          "build" => job_status(%{phase: :succeeded, outputs: %{"artifact" => "x"}}),
          "lint" => job_status(%{phase: :succeeded, outputs: %{}})
        }
      }

      assert {:ok, message_a} = JobMessageRenderer.render(job, context_fields)
      assert {:ok, message_b} = JobMessageRenderer.render(job, context_fields)

      assert Jason.encode!(message_a) == Jason.encode!(message_b)
      assert message_a == message_b
    end
  end
end
