defmodule CrestCiController.Engine.JobDefinitionTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.JobDefinition

  describe "new/1" do
    test "builds a definition with only required fields and defaults" do
      assert {:ok, job} = JobDefinition.new(%{id: "build", name: "build"})

      assert job.id == "build"
      assert job.name == "build"
      assert job.needs == []
      assert job.runs_on == []
      assert job.condition == ""
      assert job.env == %{}
      assert job.steps == []
      assert job.timeout_minutes == 360
    end

    test "builds a fully-populated definition" do
      assert {:ok, job} =
               JobDefinition.new(%{
                 id: "test",
                 name: "Test",
                 needs: ["build"],
                 runs_on: ["ubuntu-latest"],
                 condition: "${{ success() }}",
                 env: %{"NODE_ENV" => "test"},
                 steps: [%{"run" => "echo hi"}],
                 timeout_minutes: 30
               })

      assert job.id == "test"
      assert job.name == "Test"
      assert job.needs == ["build"]
      assert job.runs_on == ["ubuntu-latest"]
      assert job.condition == "${{ success() }}"
      assert job.env == %{"NODE_ENV" => "test"}
      assert job.steps == [%{"run" => "echo hi"}]
      assert job.timeout_minutes == 30
    end

    test "rejects a non-binary id" do
      assert {:error, {:invalid_id, 123}} = JobDefinition.new(%{id: 123, name: "build"})
    end

    test "rejects a non-binary name" do
      assert {:error, {:invalid_name, 123}} = JobDefinition.new(%{id: "build", name: 123})
    end

    test "rejects needs with non-binary entries" do
      assert {:error, {:invalid_needs, _}} =
               JobDefinition.new(%{id: "test", name: "test", needs: [1]})
    end

    test "rejects a non-list needs" do
      assert {:error, {:invalid_needs, "build"}} =
               JobDefinition.new(%{id: "test", name: "test", needs: "build"})
    end

    test "rejects runs_on with non-binary entries" do
      assert {:error, {:invalid_runs_on, _}} =
               JobDefinition.new(%{id: "build", name: "build", runs_on: [1]})
    end

    test "rejects a non-binary condition" do
      assert {:error, {:invalid_condition, _}} =
               JobDefinition.new(%{id: "build", name: "build", condition: true})
    end

    test "rejects env with non-binary values" do
      assert {:error, {:invalid_env, _}} =
               JobDefinition.new(%{id: "build", name: "build", env: %{"KEY" => 1}})
    end

    test "rejects env with non-binary keys" do
      assert {:error, {:invalid_env, _}} =
               JobDefinition.new(%{id: "build", name: "build", env: %{1 => "value"}})
    end

    test "rejects steps with non-map entries" do
      assert {:error, {:invalid_steps, _}} =
               JobDefinition.new(%{id: "build", name: "build", steps: ["run: echo hi"]})
    end

    test "rejects a non-list steps" do
      assert {:error, {:invalid_steps, _}} =
               JobDefinition.new(%{id: "build", name: "build", steps: "not-a-list"})
    end

    test "rejects a non-integer timeout_minutes" do
      assert {:error, {:invalid_timeout_minutes, _}} =
               JobDefinition.new(%{id: "build", name: "build", timeout_minutes: "30"})
    end

    test "rejects a completely invalid input shape" do
      assert {:error, {:invalid_job_definition, "not a map"}} = JobDefinition.new("not a map")
    end

    test "does not evaluate expressions inside step maps — steps stay in template form" do
      assert {:ok, job} =
               JobDefinition.new(%{
                 id: "build",
                 name: "build",
                 steps: [%{"run" => "echo ${{ github.sha }}"}]
               })

      assert job.steps == [%{"run" => "echo ${{ github.sha }}"}]
    end
  end

  describe "from_wire/1" do
    test "decodes the camelCase wire shape WorkflowParser builds" do
      wire = %{
        "id" => "build",
        "name" => "Build",
        "needs" => [],
        "runsOn" => ["ubuntu-latest"],
        "condition" => "",
        "env" => %{"NODE_ENV" => "test"},
        "steps" => [%{"run" => "echo hi"}],
        "timeoutMinutes" => 360
      }

      assert {:ok, job} = JobDefinition.from_wire(wire)
      assert job.id == "build"
      assert job.name == "Build"
      assert job.needs == []
      assert job.runs_on == ["ubuntu-latest"]
      assert job.condition == ""
      assert job.env == %{"NODE_ENV" => "test"}
      assert job.steps == [%{"run" => "echo hi"}]
      assert job.timeout_minutes == 360
    end

    test "applies defaults for missing optional wire fields" do
      wire = %{"id" => "build", "name" => "build"}

      assert {:ok, job} = JobDefinition.from_wire(wire)
      assert job.needs == []
      assert job.runs_on == []
      assert job.condition == ""
      assert job.env == %{}
      assert job.steps == []
      assert job.timeout_minutes == 360
    end

    test "propagates a structural error from a malformed known field" do
      wire = %{"id" => "build", "name" => "build", "timeoutMinutes" => "not-an-int"}

      assert {:error, {:invalid_timeout_minutes, "not-an-int"}} = JobDefinition.from_wire(wire)
    end

    test "rejects a non-map input" do
      assert {:error, {:invalid_job_definition, "nope"}} = JobDefinition.from_wire("nope")
    end
  end

  describe "to_wire/1" do
    test "round-trips through from_wire/1 and to_wire/1" do
      wire = %{
        "id" => "test",
        "name" => "Test",
        "needs" => ["build"],
        "runsOn" => ["ubuntu-latest"],
        "condition" => "${{ success() }}",
        "env" => %{"NODE_ENV" => "test"},
        "steps" => [%{"run" => "echo hi"}],
        "timeoutMinutes" => 30
      }

      assert {:ok, job} = JobDefinition.from_wire(wire)
      assert JobDefinition.to_wire(job) == wire
    end
  end

  describe "Jason.Encoder" do
    test "encodes to the wire JSON shape" do
      assert {:ok, job} = JobDefinition.new(%{id: "build", name: "build"})

      assert {:ok, encoded} = Jason.encode(job)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded == JobDefinition.to_wire(job)
    end
  end
end
