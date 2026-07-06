defmodule CrestCiController.Engine.PlannerTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.PlanJob
  alias CrestCiController.Engine.{GithubContext, Planner, WorkflowDefinition}

  # -- Shared fixtures ------------------------------------------------------

  defp github_context(overrides \\ %{}) do
    fields =
      Map.merge(
        %{
          actor: "octocat",
          event: %{},
          event_name: "push",
          ref: "refs/heads/main",
          repository: "octo/repo",
          sha: "deadbeef"
        },
        overrides
      )

    {:ok, context} = GithubContext.new(fields)
    context
  end

  defp definition(jobs, workflow_fields \\ %{}) do
    fields = Map.merge(%{name: "wf", on: %{"push" => %{}}, jobs: jobs}, workflow_fields)
    {:ok, def} = WorkflowDefinition.new(fields)
    def
  end

  defp job(overrides \\ %{}) do
    Map.merge(
      %{
        "runs-on" => ["ubuntu-latest"],
        "steps" => [%{"run" => "echo hi"}]
      },
      overrides
    )
  end

  defp keys(plan), do: Enum.map(plan, & &1.key)
  defp needs(plan), do: Enum.map(plan, &{&1.key, &1.needs})

  # -- Happy path: ordering ------------------------------------------------

  describe "plan/2 — deterministic topological order" do
    test "a linear chain plans in dependency order" do
      jobs = %{
        "deploy" => job(%{"needs" => "test"}),
        "build" => job(),
        "test" => job(%{"needs" => "build"})
      }

      assert {:ok, plan} = Planner.plan(definition(jobs), github_context())
      assert keys(plan) == ["build", "test", "deploy"]
      assert needs(plan) == [{"build", []}, {"test", ["build"]}, {"deploy", ["test"]}]
    end

    test "a fan-out/fan-in diamond breaks ties lexicographically" do
      jobs = %{
        "release" => job(%{"needs" => ["unit_tests", "integration_tests"]}),
        "unit_tests" => job(%{"needs" => "setup"}),
        "integration_tests" => job(%{"needs" => "setup"}),
        "setup" => job()
      }

      assert {:ok, plan} = Planner.plan(definition(jobs), github_context())

      assert keys(plan) == [
               "setup",
               "integration_tests",
               "unit_tests",
               "release"
             ]
    end

    test "independent jobs with no needs are ordered lexicographically" do
      jobs = %{"beta" => job(), "alpha" => job()}

      assert {:ok, plan} = Planner.plan(definition(jobs), github_context())
      assert keys(plan) == ["alpha", "beta"]
    end

    test "is deterministic: identical input plans byte-identically" do
      jobs = %{
        "release" => job(%{"needs" => ["unit_tests", "integration_tests"]}),
        "unit_tests" => job(%{"needs" => "setup"}),
        "integration_tests" => job(%{"needs" => "setup"}),
        "setup" => job()
      }

      def = definition(jobs)
      context = github_context()

      assert {:ok, plan_a} = Planner.plan(def, context)
      assert {:ok, plan_b} = Planner.plan(def, context)
      assert Jason.encode!(plan_a) == Jason.encode!(plan_b)
    end
  end

  # -- needs DAG validation -------------------------------------------------

  describe "plan/2 — needs DAG validation" do
    test "rejects a needs reference to a job that does not exist" do
      jobs = %{
        "build" => job(),
        "test" => job(%{"needs" => "build_missing"})
      }

      assert {:error, {:unknown_needs, offenses}} =
               Planner.plan(definition(jobs), github_context())

      assert %{job_id: "test", target: "build_missing"} in offenses
    end

    test "rejects a two-job needs cycle, naming every job in it" do
      jobs = %{
        "a" => job(%{"needs" => "b"}),
        "b" => job(%{"needs" => "a"})
      }

      assert {:error, {:cyclic_needs, cycle}} = Planner.plan(definition(jobs), github_context())
      assert Enum.sort(cycle) == ["a", "b"]
    end

    test "rejects a job that needs itself" do
      jobs = %{"a" => job(%{"needs" => "a"})}

      assert {:error, {:cyclic_needs, ["a"]}} = Planner.plan(definition(jobs), github_context())
    end

    test "a cycle downstream of an otherwise valid job is still reported" do
      jobs = %{
        "build" => job(),
        "a" => job(%{"needs" => ["build", "b"]}),
        "b" => job(%{"needs" => "a"})
      }

      assert {:error, {:cyclic_needs, cycle}} = Planner.plan(definition(jobs), github_context())
      assert Enum.sort(cycle) == ["a", "b"]
    end

    test "duplicate needs entries for the same target are tolerated" do
      jobs = %{
        "build" => job(),
        "test" => job(%{"needs" => ["build", "build"]})
      }

      assert {:ok, plan} = Planner.plan(definition(jobs), github_context())
      assert needs(plan) == [{"build", []}, {"test", ["build"]}]
    end
  end

  # -- job-level if evaluation ----------------------------------------------

  describe "plan/2 — job-level if evaluation" do
    test "a job with no if is always included" do
      jobs = %{"build" => job()}

      assert {:ok, plan} = Planner.plan(definition(jobs), github_context())
      assert keys(plan) == ["build"]
    end

    test "a truthy if referencing github.* includes the job" do
      jobs = %{"deploy" => job(%{"if" => "${{ github.ref == 'refs/heads/main' }}"})}

      assert {:ok, plan} =
               Planner.plan(definition(jobs), github_context(%{ref: "refs/heads/main"}))

      assert keys(plan) == ["deploy"]
    end

    test "a falsy if referencing github.* excludes the job" do
      jobs = %{"deploy" => job(%{"if" => "${{ github.ref == 'refs/heads/main' }}"})}

      assert {:ok, plan} =
               Planner.plan(definition(jobs), github_context(%{ref: "refs/heads/feature"}))

      assert plan == []
    end

    test "excluding one job leaves its siblings and the rest of the order intact" do
      jobs = %{
        "build" => job(),
        "deploy" => job(%{"needs" => "build", "if" => "${{ github.ref == 'refs/heads/main' }}"}),
        "notify" => job(%{"needs" => "build"})
      }

      assert {:ok, plan} =
               Planner.plan(definition(jobs), github_context(%{ref: "refs/heads/feature"}))

      assert keys(plan) == ["build", "notify"]
    end

    test "if evaluates against the workflow env -> job env merge, job winning" do
      jobs = %{
        "alpha" =>
          job(%{
            "env" => %{"SHARED" => "alpha-shared"},
            "if" => "${{ env.SHARED == 'alpha-shared' }}"
          }),
        "beta" =>
          job(%{
            "env" => %{"SHARED" => "beta-shared"},
            "if" => "${{ env.GLOBAL == 'workflow-only' }}"
          })
      }

      def =
        definition(jobs, %{env: %{"GLOBAL" => "workflow-only", "SHARED" => "workflow-shared"}})

      assert {:ok, plan} = Planner.plan(def, github_context())
      assert Enum.sort(keys(plan)) == ["alpha", "beta"]
    end

    test "an if with a parse error surfaces a structured error naming the job" do
      jobs = %{"build" => job(%{"if" => "${{ !!! }}"})}

      assert {:error, {:invalid_condition, "build", _reason}} =
               Planner.plan(definition(jobs), github_context())
    end
  end

  # -- runs-on interpolation -------------------------------------------------

  describe "plan/2 — runs-on interpolation" do
    test "a literal runs-on label passes through unchanged" do
      jobs = %{"build" => job(%{"runs-on" => ["ubuntu-latest", "self-hosted"]})}

      assert {:ok, [%PlanJob{runs_on: runs_on}]} =
               Planner.plan(definition(jobs), github_context())

      assert runs_on == ["ubuntu-latest", "self-hosted"]
    end

    test "a whole ${{ }} runs-on label is evaluated against the assembled context" do
      jobs = %{
        "build" =>
          job(%{
            "env" => %{"RUNNER" => "gpu-box"},
            "runs-on" => ["${{ env.RUNNER }}"]
          })
      }

      assert {:ok, [%PlanJob{runs_on: runs_on}]} =
               Planner.plan(definition(jobs), github_context())

      assert runs_on == ["gpu-box"]
    end

    test "a runs-on interpolation error surfaces a structured error naming the job" do
      jobs = %{"build" => job(%{"runs-on" => ["${{ !!! }}"]})}

      assert {:error, {:invalid_runs_on, "build", _reason}} =
               Planner.plan(definition(jobs), github_context())
    end
  end

  # -- misc -------------------------------------------------------------

  describe "plan/2 — misc" do
    test "rejects non-WorkflowDefinition/GithubContext input" do
      assert {:error, {:invalid_input, _}} = Planner.plan(%{}, %{})
    end

    test "an empty workflow plans to an empty list" do
      assert {:ok, []} = Planner.plan(definition(%{}), github_context())
    end

    test "job steps are carried through unevaluated" do
      jobs = %{"build" => job(%{"steps" => [%{"run" => "${{ github.ref }}"}]})}

      assert {:ok, [%PlanJob{steps: steps}]} = Planner.plan(definition(jobs), github_context())
      assert steps == [%{"run" => "${{ github.ref }}"}]
    end
  end
end
