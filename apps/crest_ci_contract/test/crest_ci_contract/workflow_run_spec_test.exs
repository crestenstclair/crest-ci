defmodule CrestCiContract.WorkflowRunSpecTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.PlanJob
  alias CrestCiContract.WorkflowRunSpec

  describe "new/1" do
    test "builds a WorkflowRunSpec with only repo/ref/sha, defaulting the rest" do
      assert {:ok, spec} =
               WorkflowRunSpec.new(%{
                 repo: "acme/widgets",
                 ref: "refs/heads/main",
                 sha: "deadbeef"
               })

      assert spec.repo == "acme/widgets"
      assert spec.ref == "refs/heads/main"
      assert spec.sha == "deadbeef"
      assert spec.concurrency_key == ""
      assert spec.placement == %{}
      assert spec.plan == []
    end

    test "builds a fully-populated WorkflowRunSpec with plan jobs as maps" do
      assert {:ok, spec} =
               WorkflowRunSpec.new(%{
                 repo: "acme/widgets",
                 ref: "refs/heads/main",
                 sha: "deadbeef",
                 concurrency_key: "acme/widgets:main",
                 placement: %{"zone" => "us-east"},
                 plan: [%{key: "build"}, %{key: "test", needs: ["build"]}]
               })

      assert spec.concurrency_key == "acme/widgets:main"
      assert spec.placement == %{"zone" => "us-east"}
      assert [%PlanJob{key: "build"}, %PlanJob{key: "test", needs: ["build"]}] = spec.plan
    end

    test "accepts plan entries that are already PlanJob structs" do
      {:ok, job} = PlanJob.new(%{key: "build"})

      assert {:ok, spec} =
               WorkflowRunSpec.new(%{
                 repo: "acme/widgets",
                 ref: "refs/heads/main",
                 sha: "deadbeef",
                 plan: [job]
               })

      assert spec.plan == [job]
    end

    test "rejects a missing or empty repo/ref/sha" do
      assert {:error, :invalid_repo} = WorkflowRunSpec.new(%{ref: "main", sha: "abc"})
      assert {:error, :invalid_repo} = WorkflowRunSpec.new(%{repo: "", ref: "main", sha: "abc"})
      assert {:error, :invalid_ref} = WorkflowRunSpec.new(%{repo: "r", ref: "", sha: "abc"})
      assert {:error, :invalid_sha} = WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: ""})
    end

    test "rejects a non-map placement" do
      assert {:error, {:invalid_placement, _}} =
               WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: "abc", placement: "nope"})
    end

    test "rejects a plan entry that fails PlanJob validation" do
      assert {:error, {:invalid_plan, _}} =
               WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: "abc", plan: [%{key: ""}]})
    end

    test "rejects a plan entry that is not a map or PlanJob" do
      assert {:error, {:invalid_plan, _}} =
               WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: "abc", plan: ["build"]})
    end

    test "rejects a plan that is not a list" do
      assert {:error, {:invalid_plan, _}} =
               WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: "abc", plan: %{}})
    end

    test "rejects a plan with two entries sharing the same JobKey" do
      assert {:error, {:invalid_plan, {:duplicate_job_key, "build"}}} =
               WorkflowRunSpec.new(%{
                 repo: "r",
                 ref: "main",
                 sha: "abc",
                 plan: [%{key: "build"}, %{key: "test", needs: ["build"]}, %{key: "build"}]
               })
    end

    test "rejects a plan with duplicate JobKeys given as pre-built PlanJob structs" do
      {:ok, job_a} = PlanJob.new(%{key: "build"})
      {:ok, job_b} = PlanJob.new(%{key: "build"})

      assert {:error, {:invalid_plan, {:duplicate_job_key, "build"}}} =
               WorkflowRunSpec.new(%{repo: "r", ref: "main", sha: "abc", plan: [job_a, job_b]})
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips through the Kubernetes camelCase wire shape" do
      {:ok, spec} =
        WorkflowRunSpec.new(%{
          repo: "acme/widgets",
          ref: "refs/heads/main",
          sha: "deadbeef",
          concurrency_key: "acme/widgets:main",
          placement: %{"zone" => "us-east"},
          plan: [%{key: "build", needs: []}, %{key: "test", needs: ["build"]}]
        })

      wire = WorkflowRunSpec.to_wire(spec)

      assert wire == %{
               "concurrencyKey" => "acme/widgets:main",
               "placement" => %{"zone" => "us-east"},
               "plan" => [
                 %{
                   "displayName" => "",
                   "key" => "build",
                   "needs" => [],
                   "runsOn" => [],
                   "steps" => []
                 },
                 %{
                   "displayName" => "",
                   "key" => "test",
                   "needs" => ["build"],
                   "runsOn" => [],
                   "steps" => []
                 }
               ],
               "ref" => "refs/heads/main",
               "repo" => "acme/widgets",
               "sha" => "deadbeef"
             }

      assert {:ok, decoded} = WorkflowRunSpec.from_wire(wire)
      assert decoded == spec
    end

    test "from_wire/1 defaults missing optional fields" do
      assert {:ok, spec} =
               WorkflowRunSpec.from_wire(%{
                 "repo" => "acme/widgets",
                 "ref" => "refs/heads/main",
                 "sha" => "deadbeef"
               })

      assert spec.concurrency_key == ""
      assert spec.placement == %{}
      assert spec.plan == []
    end

    test "from_wire/1 rejects a non-map input" do
      assert {:error, {:invalid_workflow_run_spec, _}} = WorkflowRunSpec.from_wire("nope")
    end

    test "from_wire/1 propagates a malformed plan entry error" do
      assert {:error, {:invalid_plan, _}} =
               WorkflowRunSpec.from_wire(%{
                 "repo" => "r",
                 "ref" => "main",
                 "sha" => "abc",
                 "plan" => [%{"key" => ""}]
               })
    end

    test "from_wire/1 rejects a plan with duplicate JobKeys" do
      assert {:error, {:invalid_plan, {:duplicate_job_key, "build"}}} =
               WorkflowRunSpec.from_wire(%{
                 "repo" => "r",
                 "ref" => "main",
                 "sha" => "abc",
                 "plan" => [%{"key" => "build"}, %{"key" => "build"}]
               })
    end

    test "round-trips through actual JSON encode/decode via Jason" do
      {:ok, spec} =
        WorkflowRunSpec.new(%{
          repo: "acme/widgets",
          ref: "refs/heads/main",
          sha: "deadbeef",
          concurrency_key: "acme/widgets:main",
          placement: %{"zone" => "us-east"},
          plan: [%{key: "build"}]
        })

      encoded = Jason.encode!(spec)
      decoded_wire = Jason.decode!(encoded)

      assert {:ok, decoded} = WorkflowRunSpec.from_wire(decoded_wire)
      assert decoded == spec
    end
  end
end
