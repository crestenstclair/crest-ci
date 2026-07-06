defmodule CrestCiContract.PlanJobTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.PlanJob

  describe "new/1" do
    test "builds a PlanJob with only a key, defaulting the rest" do
      assert {:ok, plan_job} = PlanJob.new(%{key: "build"})

      assert plan_job.key == "build"
      assert plan_job.display_name == ""
      assert plan_job.needs == []
      assert plan_job.runs_on == []
      assert plan_job.steps == []
    end

    test "builds a fully-populated PlanJob" do
      assert {:ok, plan_job} =
               PlanJob.new(%{
                 display_name: "Build",
                 key: "build",
                 needs: ["setup"],
                 runs_on: ["linux", "x64"],
                 steps: [%{"name" => "checkout"}, %{"name" => "compile"}]
               })

      assert plan_job.display_name == "Build"
      assert plan_job.key == "build"
      assert plan_job.needs == ["setup"]
      assert plan_job.runs_on == ["linux", "x64"]
      assert plan_job.steps == [%{"name" => "checkout"}, %{"name" => "compile"}]
    end

    test "accepts matrix-style job keys" do
      assert {:ok, plan_job} = PlanJob.new(%{key: "test/m-3f9a2c"})
      assert plan_job.key == "test/m-3f9a2c"
    end

    test "rejects a missing or invalid key" do
      assert {:error, :invalid_job_key} = PlanJob.new(%{key: ""})
      assert {:error, :invalid_job_key} = PlanJob.new(%{key: nil})
      assert {:error, :invalid_job_key} = PlanJob.new(%{})
    end

    test "rejects needs containing a non-binary or empty entry" do
      assert {:error, {:invalid_needs, _}} = PlanJob.new(%{key: "build", needs: [123]})
      assert {:error, {:invalid_needs, _}} = PlanJob.new(%{key: "build", needs: [""]})
      assert {:error, {:invalid_needs, _}} = PlanJob.new(%{key: "build", needs: "setup"})
    end

    test "rejects a job that lists itself as a dependency (self-referential edge)" do
      assert {:error, {:invalid_needs, _}} = PlanJob.new(%{key: "build", needs: ["build"]})

      assert {:error, {:invalid_needs, _}} =
               PlanJob.new(%{key: "build", needs: ["setup", "build"]})
    end

    test "rejects duplicate entries in needs (no double-counted edges)" do
      assert {:error, {:invalid_needs, _}} =
               PlanJob.new(%{key: "build", needs: ["setup", "setup"]})
    end

    test "rejects runs_on that is not a list of binaries" do
      assert {:error, {:invalid_runs_on, _}} = PlanJob.new(%{key: "build", runs_on: [1, 2]})
      assert {:error, {:invalid_runs_on, _}} = PlanJob.new(%{key: "build", runs_on: "linux"})
    end

    test "rejects steps that is not a list of maps" do
      assert {:error, {:invalid_steps, _}} = PlanJob.new(%{key: "build", steps: ["run"]})
      assert {:error, {:invalid_steps, _}} = PlanJob.new(%{key: "build", steps: %{}})
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips through the Kubernetes camelCase wire shape" do
      {:ok, plan_job} =
        PlanJob.new(%{
          display_name: "Build",
          key: "build",
          needs: ["setup"],
          runs_on: ["linux"],
          steps: [%{"name" => "checkout"}]
        })

      wire = PlanJob.to_wire(plan_job)

      assert wire == %{
               "displayName" => "Build",
               "key" => "build",
               "needs" => ["setup"],
               "runsOn" => ["linux"],
               "steps" => [%{"name" => "checkout"}]
             }

      assert {:ok, decoded} = PlanJob.from_wire(wire)
      assert decoded == plan_job
    end

    test "from_wire/1 defaults missing optional fields" do
      assert {:ok, plan_job} = PlanJob.from_wire(%{"key" => "build"})

      assert plan_job.display_name == ""
      assert plan_job.needs == []
      assert plan_job.runs_on == []
      assert plan_job.steps == []
    end

    test "round-trips through actual JSON encode/decode via Jason" do
      {:ok, plan_job} =
        PlanJob.new(%{
          display_name: "Build",
          key: "build",
          needs: ["setup"],
          runs_on: ["linux"],
          steps: [%{"name" => "checkout"}]
        })

      encoded = Jason.encode!(plan_job)
      decoded_wire = Jason.decode!(encoded)

      assert {:ok, decoded} = PlanJob.from_wire(decoded_wire)
      assert decoded == plan_job
    end
  end
end
