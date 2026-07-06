defmodule CrestCiController.Engine.ContextAssemblerTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.ContextAssembler
  alias CrestCiController.Engine.GithubContext
  alias CrestCiContract.JobStatus

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

  describe "build/1" do
    test "assembles github, needs, and env with no declared dependencies" do
      github = github_context()

      assert {:ok, context} =
               ContextAssembler.build(%{
                 github_context: github,
                 workflow_env: %{"A" => "1"},
                 job_env: %{"B" => "2"}
               })

      assert context["github"] == GithubContext.to_expr_context(github)
      assert context["needs"] == %{}
      assert context["env"] == %{"A" => "1", "B" => "2"}
    end

    test "job env wins over workflow env on key collision" do
      github = github_context()

      assert {:ok, context} =
               ContextAssembler.build(%{
                 github_context: github,
                 workflow_env: %{"SHARED" => "workflow", "ONLY_WORKFLOW" => "w"},
                 job_env: %{"SHARED" => "job", "ONLY_JOB" => "j"}
               })

      assert context["env"] == %{
               "SHARED" => "job",
               "ONLY_WORKFLOW" => "w",
               "ONLY_JOB" => "j"
             }
    end

    test "defaults workflow_env, job_env, needs, and job_statuses when omitted" do
      github = github_context()

      assert {:ok, context} = ContextAssembler.build(%{github_context: github})

      assert context["env"] == %{}
      assert context["needs"] == %{}
    end

    test "maps a succeeded dependency's phase to result success with its outputs" do
      github = github_context()

      status =
        job_status(%{phase: :succeeded, outputs: %{"artifact" => "build-42"}})

      assert {:ok, context} =
               ContextAssembler.build(%{
                 github_context: github,
                 needs: ["build"],
                 job_statuses: %{"build" => status}
               })

      assert context["needs"] == %{
               "build" => %{"result" => "success", "outputs" => %{"artifact" => "build-42"}}
             }
    end

    test "maps each terminal phase to its GitHub Actions result string" do
      github = github_context()

      phase_results = %{
        succeeded: "success",
        failed: "failure",
        cancelled: "cancelled",
        skipped: "skipped"
      }

      for {phase, result} <- phase_results do
        status = job_status(%{phase: phase})

        assert {:ok, context} =
                 ContextAssembler.build(%{
                   github_context: github,
                   needs: ["dep"],
                   job_statuses: %{"dep" => status}
                 })

        assert context["needs"]["dep"]["result"] == result
      end
    end

    test "assembles multiple needs, each keyed by job id" do
      github = github_context()

      build_status = job_status(%{phase: :succeeded, outputs: %{"x" => "1"}})
      test_status = job_status(%{phase: :failed})

      assert {:ok, context} =
               ContextAssembler.build(%{
                 github_context: github,
                 needs: ["build", "test"],
                 job_statuses: %{"build" => build_status, "test" => test_status}
               })

      assert context["needs"]["build"] == %{"result" => "success", "outputs" => %{"x" => "1"}}
      assert context["needs"]["test"] == %{"result" => "failure", "outputs" => %{}}
    end

    test "rejects a declared need with no corresponding job_statuses entry" do
      github = github_context()

      assert {:error, {:missing_need_status, "build"}} =
               ContextAssembler.build(%{
                 github_context: github,
                 needs: ["build"],
                 job_statuses: %{}
               })
    end

    test "rejects a declared need whose dependency has not reached a terminal phase" do
      github = github_context()
      status = job_status(%{phase: :running})

      assert {:error, {:unsatisfied_need, "build", :running}} =
               ContextAssembler.build(%{
                 github_context: github,
                 needs: ["build"],
                 job_statuses: %{"build" => status}
               })
    end

    test "rejects a non-GithubContext github_context" do
      assert {:error, {:invalid_github_context, "not-a-context"}} =
               ContextAssembler.build(%{github_context: "not-a-context"})
    end

    test "rejects a missing github_context" do
      assert {:error, {:invalid_github_context, nil}} = ContextAssembler.build(%{})
    end

    test "rejects a non-map workflow_env" do
      github = github_context()

      assert {:error, {:invalid_workflow_env, "nope"}} =
               ContextAssembler.build(%{github_context: github, workflow_env: "nope"})
    end

    test "rejects a workflow_env with a non-binary value" do
      github = github_context()

      assert {:error, {:invalid_workflow_env, %{"A" => 1}}} =
               ContextAssembler.build(%{github_context: github, workflow_env: %{"A" => 1}})
    end

    test "rejects a non-map job_env" do
      github = github_context()

      assert {:error, {:invalid_job_env, "nope"}} =
               ContextAssembler.build(%{github_context: github, job_env: "nope"})
    end

    test "rejects a non-list needs" do
      github = github_context()

      assert {:error, {:invalid_needs, "nope"}} =
               ContextAssembler.build(%{github_context: github, needs: "nope"})
    end

    test "rejects a needs list with a non-binary entry" do
      github = github_context()

      assert {:error, {:invalid_needs, [:build]}} =
               ContextAssembler.build(%{github_context: github, needs: [:build]})
    end

    test "rejects a non-map job_statuses" do
      github = github_context()

      assert {:error, {:invalid_job_statuses, "nope"}} =
               ContextAssembler.build(%{github_context: github, job_statuses: "nope"})
    end

    test "rejects a job_statuses value that is not a JobStatus struct" do
      github = github_context()

      assert {:error, {:invalid_job_statuses, %{"build" => %{}}}} =
               ContextAssembler.build(%{
                 github_context: github,
                 job_statuses: %{"build" => %{}}
               })
    end

    test "is deterministic: identical input yields identical output" do
      github = github_context()
      status = job_status(%{phase: :succeeded, outputs: %{"x" => "1"}})

      fields = %{
        github_context: github,
        workflow_env: %{"A" => "1"},
        job_env: %{"B" => "2"},
        needs: ["build"],
        job_statuses: %{"build" => status}
      }

      assert ContextAssembler.build(fields) == ContextAssembler.build(fields)
    end
  end
end
