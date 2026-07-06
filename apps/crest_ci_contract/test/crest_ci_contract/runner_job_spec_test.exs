defmodule CrestCiContract.RunnerJobSpecTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.RunnerJobSpec

  describe "new/1" do
    test "builds a struct with sensible defaults when only required fields are given" do
      assert {:ok, %RunnerJobSpec{} = spec} =
               RunnerJobSpec.new(%{
                 job_key: "build",
                 run_ref: "refs/heads/main",
                 runs_on: ["linux"]
               })

      assert spec.job_key == "build"
      assert spec.run_ref == "refs/heads/main"
      assert spec.job_message == %{}
      assert spec.runs_on == ["linux"]
    end

    test "builds a struct with all fields populated" do
      assert {:ok, %RunnerJobSpec{} = spec} =
               RunnerJobSpec.new(%{
                 job_key: "test/m-3f9a2c",
                 job_message: %{"steps" => [%{"run" => "mix test"}]},
                 run_ref: "refs/heads/main",
                 runs_on: ["linux", "x64"]
               })

      assert spec.job_key == "test/m-3f9a2c"
      assert spec.job_message == %{"steps" => [%{"run" => "mix test"}]}
      assert spec.run_ref == "refs/heads/main"
      assert spec.runs_on == ["linux", "x64"]
    end

    test "rejects a missing/empty job_key" do
      assert {:error, :invalid_job_key} =
               RunnerJobSpec.new(%{run_ref: "refs/heads/main", runs_on: ["linux"]})

      assert {:error, :invalid_job_key} =
               RunnerJobSpec.new(%{job_key: "", run_ref: "x", runs_on: ["linux"]})

      assert {:error, :invalid_job_key} =
               RunnerJobSpec.new(%{job_key: 123, run_ref: "x", runs_on: ["linux"]})
    end

    test "rejects a missing/empty run_ref" do
      assert {:error, :invalid_run_ref} =
               RunnerJobSpec.new(%{job_key: "build", runs_on: ["linux"]})

      assert {:error, :invalid_run_ref} =
               RunnerJobSpec.new(%{job_key: "build", run_ref: "", runs_on: ["linux"]})
    end

    test "rejects a non-list or non-string-list runs_on" do
      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.new(%{job_key: "build", run_ref: "x", runs_on: "linux"})

      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.new(%{job_key: "build", run_ref: "x", runs_on: ["linux", 1]})
    end

    test "rejects a missing, nil, or empty runs_on — an unplaced RunnerJobSpec is unrepresentable" do
      assert {:error, :invalid_runs_on} = RunnerJobSpec.new(%{job_key: "build", run_ref: "x"})

      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.new(%{job_key: "build", run_ref: "x", runs_on: []})

      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.new(%{job_key: "build", run_ref: "x", runs_on: nil})
    end

    test "rejects a non-map job_message" do
      assert {:error, :invalid_job_message} =
               RunnerJobSpec.new(%{
                 job_key: "build",
                 run_ref: "x",
                 runs_on: ["linux"],
                 job_message: "nope"
               })
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces camelCase keys" do
      {:ok, spec} =
        RunnerJobSpec.new(%{
          job_key: "build",
          job_message: %{"steps" => []},
          run_ref: "refs/heads/main",
          runs_on: ["linux"]
        })

      assert RunnerJobSpec.to_wire(spec) == %{
               "jobKey" => "build",
               "jobMessage" => %{"steps" => []},
               "runRef" => "refs/heads/main",
               "runsOn" => ["linux"]
             }
    end

    test "from_wire decodes a Kubernetes-shaped map back into a RunnerJobSpec" do
      wire = %{
        "jobKey" => "test/m-3f9a2c",
        "jobMessage" => %{"steps" => [%{"run" => "mix test"}]},
        "runRef" => "refs/heads/main",
        "runsOn" => ["linux", "x64"]
      }

      assert {:ok, %RunnerJobSpec{} = spec} = RunnerJobSpec.from_wire(wire)
      assert spec.job_key == "test/m-3f9a2c"
      assert spec.job_message == %{"steps" => [%{"run" => "mix test"}]}
      assert spec.run_ref == "refs/heads/main"
      assert spec.runs_on == ["linux", "x64"]
    end

    test "from_wire rejects a missing jobKey" do
      assert {:error, :invalid_job_key} =
               RunnerJobSpec.from_wire(%{"runRef" => "x", "runsOn" => ["linux"]})
    end

    test "from_wire rejects a missing runsOn — no wire-decode path can produce an unplaced spec" do
      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.from_wire(%{"jobKey" => "build", "runRef" => "refs/heads/main"})

      assert {:error, :invalid_runs_on} =
               RunnerJobSpec.from_wire(%{
                 "jobKey" => "build",
                 "runRef" => "refs/heads/main",
                 "runsOn" => []
               })
    end

    test "to_wire/from_wire round-trips without loss" do
      {:ok, original} =
        RunnerJobSpec.new(%{
          job_key: "deploy",
          job_message: %{"env" => %{"STAGE" => "prod"}},
          run_ref: "refs/tags/v1.0.0",
          runs_on: ["linux", "arm64"]
        })

      assert {:ok, roundtripped} =
               original |> RunnerJobSpec.to_wire() |> RunnerJobSpec.from_wire()

      assert roundtripped == original
    end

    test "defaults missing optional job_message but still requires runsOn" do
      assert {:ok, %RunnerJobSpec{} = spec} =
               RunnerJobSpec.from_wire(%{
                 "jobKey" => "build",
                 "runRef" => "refs/heads/main",
                 "runsOn" => ["linux"]
               })

      assert spec.job_message == %{}
      assert spec.runs_on == ["linux"]
    end
  end

  describe "Jason.Encoder" do
    test "Jason.encode!/1 serializes to the camelCase wire shape" do
      {:ok, spec} =
        RunnerJobSpec.new(%{
          job_key: "build",
          job_message: %{"steps" => []},
          run_ref: "refs/heads/main",
          runs_on: ["linux"]
        })

      encoded = Jason.encode!(spec)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded == %{
               "jobKey" => "build",
               "jobMessage" => %{"steps" => []},
               "runRef" => "refs/heads/main",
               "runsOn" => ["linux"]
             }
    end
  end
end
