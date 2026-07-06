defmodule CrestCiController.Engine.WorkflowDefinitionTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.WorkflowDefinition

  describe "new/1" do
    test "builds a definition with only defaults" do
      assert {:ok, definition} = WorkflowDefinition.new(%{})

      assert definition.name == nil
      assert definition.on == %{}
      assert definition.env == %{}
      assert definition.jobs == %{}
      assert definition.raw_yaml == ""
    end

    test "builds a fully-populated definition" do
      assert {:ok, definition} =
               WorkflowDefinition.new(%{
                 name: "CI",
                 on: %{"push" => %{"branches" => ["main"]}},
                 env: %{"NODE_ENV" => "test"},
                 jobs: %{"build" => %{"runs-on" => "ubuntu-latest"}},
                 raw_yaml: "name: CI\non:\n  push:\n"
               })

      assert definition.name == "CI"
      assert definition.on == %{"push" => %{"branches" => ["main"]}}
      assert definition.env == %{"NODE_ENV" => "test"}
      assert definition.jobs == %{"build" => %{"runs-on" => "ubuntu-latest"}}
      assert definition.raw_yaml == "name: CI\non:\n  push:\n"
    end

    test "rejects a non-binary name" do
      assert {:error, {:invalid_name, 123}} = WorkflowDefinition.new(%{name: 123})
    end

    test "rejects a non-map on" do
      assert {:error, {:invalid_on, "push"}} = WorkflowDefinition.new(%{on: "push"})
    end

    test "rejects env with non-binary values" do
      assert {:error, {:invalid_env, _}} = WorkflowDefinition.new(%{env: %{"KEY" => 1}})
    end

    test "rejects env with non-binary keys" do
      assert {:error, {:invalid_env, _}} = WorkflowDefinition.new(%{env: %{1 => "value"}})
    end

    test "rejects jobs with non-binary keys" do
      assert {:error, {:invalid_jobs, _}} = WorkflowDefinition.new(%{jobs: %{1 => %{}}})
    end

    test "rejects jobs with non-map values" do
      assert {:error, {:invalid_jobs, _}} = WorkflowDefinition.new(%{jobs: %{"build" => "nope"}})
    end

    test "rejects a non-binary raw_yaml" do
      assert {:error, {:invalid_raw_yaml, _}} = WorkflowDefinition.new(%{raw_yaml: 123})
    end

    test "rejects a completely invalid input shape" do
      assert {:error, {:invalid_workflow_definition, "not a map"}} =
               WorkflowDefinition.new("not a map")
    end
  end

  describe "from_decoded/2" do
    test "builds successfully with no warnings when only known keys are present" do
      decoded = %{
        "name" => "CI",
        "on" => %{"push" => %{}},
        "env" => %{"NODE_ENV" => "test"},
        "jobs" => %{"build" => %{"runs-on" => "ubuntu-latest"}}
      }

      assert {:ok, definition, warnings} = WorkflowDefinition.from_decoded(decoded, "raw")
      assert warnings == []
      assert definition.name == "CI"
      assert definition.jobs == %{"build" => %{"runs-on" => "ubuntu-latest"}}
      assert definition.raw_yaml == "raw"
    end

    test "retains unknown top-level keys as warnings, never errors" do
      decoded = %{
        "name" => "CI",
        "permissions" => %{"contents" => "read"},
        "run-name" => "Build ${{ github.ref }}",
        "jobs" => %{}
      }

      assert {:ok, definition, warnings} = WorkflowDefinition.from_decoded(decoded, "raw")
      assert definition.name == "CI"

      assert warnings == [
               {:unknown_key, "permissions"},
               {:unknown_key, "run-name"}
             ]
    end

    test "defaults missing known keys" do
      assert {:ok, definition, warnings} = WorkflowDefinition.from_decoded(%{}, "raw")
      assert warnings == []
      assert definition.name == nil
      assert definition.on == %{}
      assert definition.env == %{}
      assert definition.jobs == %{}
    end

    test "still reports a structural error for a malformed known key" do
      decoded = %{"env" => %{"KEY" => 1}}
      assert {:error, {:invalid_env, _}} = WorkflowDefinition.from_decoded(decoded, "raw")
    end

    test "rejects a non-map decoded input" do
      assert {:error, {:invalid_workflow_definition, "bogus"}} =
               WorkflowDefinition.from_decoded("bogus", "raw")
    end

    test "is deterministic: identical input yields an identical result" do
      decoded = %{
        "name" => "CI",
        "concurrency" => "group",
        "jobs" => %{"build" => %{}}
      }

      assert WorkflowDefinition.from_decoded(decoded, "raw") ==
               WorkflowDefinition.from_decoded(decoded, "raw")
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips a fully-populated definition" do
      {:ok, definition} =
        WorkflowDefinition.new(%{
          name: "CI",
          on: %{"push" => %{}},
          env: %{"NODE_ENV" => "test"},
          jobs: %{"build" => %{"runs-on" => "ubuntu-latest"}},
          raw_yaml: "name: CI\n"
        })

      wire = WorkflowDefinition.to_wire(definition)

      assert wire == %{
               "name" => "CI",
               "on" => %{"push" => %{}},
               "env" => %{"NODE_ENV" => "test"},
               "jobs" => %{"build" => %{"runs-on" => "ubuntu-latest"}},
               "rawYaml" => "name: CI\n"
             }

      assert {:ok, roundtripped} = WorkflowDefinition.from_wire(wire)
      assert roundtripped == definition
    end

    test "from_wire defaults missing wire keys" do
      assert {:ok, definition} = WorkflowDefinition.from_wire(%{})
      assert definition.name == nil
      assert definition.on == %{}
      assert definition.env == %{}
      assert definition.jobs == %{}
      assert definition.raw_yaml == ""
    end

    test "from_wire rejects a non-map input" do
      assert {:error, {:invalid_workflow_definition, "bogus"}} =
               WorkflowDefinition.from_wire("bogus")
    end
  end

  describe "Jason.Encoder" do
    test "encodes to the wire shape" do
      {:ok, definition} =
        WorkflowDefinition.new(%{
          name: "CI",
          jobs: %{"build" => %{"runs-on" => "ubuntu-latest"}}
        })

      encoded = Jason.encode!(definition)
      decoded = Jason.decode!(encoded)

      assert decoded == %{
               "name" => "CI",
               "on" => %{},
               "env" => %{},
               "jobs" => %{"build" => %{"runs-on" => "ubuntu-latest"}},
               "rawYaml" => ""
             }
    end
  end
end
