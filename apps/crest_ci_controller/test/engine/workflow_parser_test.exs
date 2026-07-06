defmodule CrestCiController.Engine.WorkflowParserTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.WorkflowParser

  describe "parse/1 — happy path" do
    test "parses a minimal workflow with no warnings" do
      yaml = """
      name: CI
      on:
        push:
          branches: [main]
      jobs:
        build:
          runs-on: ubuntu-latest
          steps:
            - run: echo hi
      """

      assert {:ok, definition, warnings} = WorkflowParser.parse(yaml)
      assert definition.name == "CI"
      assert definition.on == %{"push" => %{"branches" => ["main"]}}
      assert %{"build" => %{"runs-on" => "ubuntu-latest"}} = definition.jobs
      assert definition.raw_yaml == yaml
      assert warnings == []
    end

    test "resolves a plain YAML anchor/alias (no merge key)" do
      yaml = """
      shared: &branches
        - main
        - develop
      on:
        push:
          branches: *branches
        pull_request:
          branches: *branches
      jobs:
        build:
          runs-on: ubuntu-latest
          steps: []
      """

      assert {:ok, definition, warnings} = WorkflowParser.parse(yaml)
      assert definition.on["push"]["branches"] == ["main", "develop"]
      assert definition.on["pull_request"]["branches"] == ["main", "develop"]
      assert {:unknown_key, "shared"} in warnings
    end
  end

  describe "parse/1 — merge keys" do
    test "a single merge key is resolved and explicit keys win over merged ones" do
      yaml = """
      x-job-defaults: &job_defaults
        runs-on: ubuntu-latest
        timeout-minutes: 15

      jobs:
        build:
          <<: *job_defaults
          timeout-minutes: 30
          steps:
            - run: echo hi
      """

      assert {:ok, definition, _warnings} = WorkflowParser.parse(yaml)
      job = definition.jobs["build"]
      assert job["runs-on"] == "ubuntu-latest"
      assert job["timeout-minutes"] == 30
      refute Map.has_key?(job, "<<")
    end

    test "a merge-key sequence resolves with earlier entries winning on conflict" do
      yaml = """
      big: &big
        retries: 10
      small: &small
        retries: 1

      jobs:
        build:
          <<: [*big, *small]
          runs-on: ubuntu-latest
          steps: []
      """

      assert {:ok, definition, warnings} = WorkflowParser.parse(yaml)
      job = definition.jobs["build"]
      assert job["retries"] == 10
      assert {:unknown_key, "jobs.build.retries"} in warnings
    end
  end

  describe "parse/1 — unknown keys become warnings" do
    test "an unknown top-level key is a warning, not an error" do
      yaml = """
      name: CI
      permissions:
        contents: read
      jobs:
        build:
          runs-on: ubuntu-latest
          steps: []
      """

      assert {:ok, _definition, warnings} = WorkflowParser.parse(yaml)
      assert {:unknown_key, "permissions"} in warnings
    end

    test "an unknown job-level key is a warning carrying the dotted key path" do
      yaml = """
      jobs:
        build:
          runs-on: ubuntu-latest
          concurrency: build-group
          steps: []
      """

      assert {:ok, _definition, warnings} = WorkflowParser.parse(yaml)
      assert {:unknown_key, "jobs.build.concurrency"} in warnings
    end
  end

  describe "parse/1 — scalar-to-list job field normalization" do
    test "accepts a scalar needs and a scalar runs-on without erroring" do
      yaml = """
      jobs:
        build:
          runs-on: ubuntu-latest
          steps: []
        test:
          needs: build
          runs-on: ubuntu-latest
          steps: []
      """

      assert {:ok, _definition, _warnings} = WorkflowParser.parse(yaml)
    end
  end

  describe "parse/1 — errors" do
    test "returns a yaml syntax error for malformed YAML" do
      bad_yaml = "name: CI\n  on: push\n\tbad: [unterminated"

      assert {:error, {:yaml_syntax_error, message}} = WorkflowParser.parse(bad_yaml)
      assert is_binary(message)
    end

    test "returns an error for a non-mapping document (a bare list)" do
      yaml = "- just\n- a\n- list\n"

      assert {:error, {:invalid_workflow_document, ["just", "a", "list"]}} =
               WorkflowParser.parse(yaml)
    end

    test "returns an error for a non-mapping document (a bare scalar)" do
      yaml = "just a scalar"

      assert {:error, {:invalid_workflow_document, "just a scalar"}} = WorkflowParser.parse(yaml)
    end

    test "propagates a workflow-level structural error (invalid env)" do
      yaml = """
      env:
        NODE_ENV: 1
      jobs:
        build:
          runs-on: ubuntu-latest
          steps: []
      """

      assert {:error, {:invalid_env, _}} = WorkflowParser.parse(yaml)
    end

    test "a non-map job value is rejected at the workflow level (WorkflowDefinition's own jobs shape check)" do
      yaml = """
      jobs:
        build: not-a-map
      """

      assert {:error, {:invalid_jobs, %{"build" => "not-a-map"}}} = WorkflowParser.parse(yaml)
    end

    test "rejects non-binary input outright" do
      assert {:error, {:invalid_yaml_input, 123}} = WorkflowParser.parse(123)
    end
  end
end
