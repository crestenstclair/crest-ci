defmodule CrestCiController.Cluster.RunnerPodSpecTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Cluster.RunnerPodSpec

  @required_fields %{
    name: "run-01hz8k3f9x-build",
    namespace: "crest-ci-runners",
    image: "ghcr.io/example/runner:2.319.1",
    service_account: "crest-runner",
    active_deadline_seconds: 3600
  }

  describe "new/1 — defaults" do
    test "builds a RunnerPodSpec with only required fields, defaulting the rest to the laptop profile" do
      assert {:ok, spec} = RunnerPodSpec.new(@required_fields)

      assert spec.name == "run-01hz8k3f9x-build"
      assert spec.namespace == "crest-ci-runners"
      assert spec.image == "ghcr.io/example/runner:2.319.1"
      assert spec.service_account == "crest-runner"
      assert spec.active_deadline_seconds == 3600

      # D2 §10 laptop profile defaults.
      assert spec.cpu_request == "100m"
      assert spec.cpu_limit == "500m"
      assert spec.mem_request == "256Mi"
      assert spec.mem_limit == "768Mi"

      assert spec.env == %{}
      assert spec.labels == %{}
    end

    test "builds a fully-populated RunnerPodSpec" do
      fields =
        Map.merge(@required_fields, %{
          cpu_request: "250m",
          cpu_limit: "1",
          mem_request: "512Mi",
          mem_limit: "1Gi",
          env: %{"RUNNER_MODE" => "k8s"},
          labels: %{"app.kubernetes.io/name" => "crest-runner", "run" => "01hz8k3f9x"}
        })

      assert {:ok, spec} = RunnerPodSpec.new(fields)

      assert spec.cpu_request == "250m"
      assert spec.cpu_limit == "1"
      assert spec.mem_request == "512Mi"
      assert spec.mem_limit == "1Gi"
      assert spec.env == %{"RUNNER_MODE" => "k8s"}
      assert spec.labels == %{"app.kubernetes.io/name" => "crest-runner", "run" => "01hz8k3f9x"}
    end
  end

  describe "new/1 — name validation" do
    test "rejects a missing or empty name" do
      assert {:error, {:invalid_name, nil}} =
               RunnerPodSpec.new(Map.delete(@required_fields, :name))

      assert {:error, {:invalid_name, ""}} =
               RunnerPodSpec.new(Map.put(@required_fields, :name, ""))
    end

    test "rejects a name with uppercase or illegal characters" do
      assert {:error, {:invalid_name, _}} =
               RunnerPodSpec.new(Map.put(@required_fields, :name, "Run-Bad"))

      assert {:error, {:invalid_name, _}} =
               RunnerPodSpec.new(Map.put(@required_fields, :name, "run_bad"))

      assert {:error, {:invalid_name, _}} =
               RunnerPodSpec.new(Map.put(@required_fields, :name, "-leading-dash"))
    end

    test "rejects a name longer than 253 characters" do
      too_long = String.duplicate("a", 254)

      assert {:error, {:invalid_name, ^too_long}} =
               RunnerPodSpec.new(Map.put(@required_fields, :name, too_long))
    end
  end

  describe "new/1 — namespace and service_account validation" do
    test "rejects an invalid namespace" do
      assert {:error, {:invalid_namespace, _}} =
               RunnerPodSpec.new(Map.put(@required_fields, :namespace, "Bad_NS"))

      assert {:error, {:invalid_namespace, nil}} =
               RunnerPodSpec.new(Map.delete(@required_fields, :namespace))
    end

    test "rejects a namespace longer than 63 characters" do
      too_long = String.duplicate("a", 64)

      assert {:error, {:invalid_namespace, ^too_long}} =
               RunnerPodSpec.new(Map.put(@required_fields, :namespace, too_long))
    end

    test "rejects an invalid service_account" do
      assert {:error, {:invalid_service_account, _}} =
               RunnerPodSpec.new(Map.put(@required_fields, :service_account, "Bad SA"))

      assert {:error, {:invalid_service_account, nil}} =
               RunnerPodSpec.new(Map.delete(@required_fields, :service_account))
    end
  end

  describe "new/1 — image validation" do
    test "rejects a missing or empty image" do
      assert {:error, {:invalid_image, nil}} =
               RunnerPodSpec.new(Map.delete(@required_fields, :image))

      assert {:error, {:invalid_image, ""}} =
               RunnerPodSpec.new(Map.put(@required_fields, :image, ""))
    end
  end

  describe "new/1 — active_deadline_seconds validation" do
    test "rejects zero, negative, non-integer, or missing values" do
      assert {:error, {:invalid_active_deadline_seconds, 0}} =
               RunnerPodSpec.new(Map.put(@required_fields, :active_deadline_seconds, 0))

      assert {:error, {:invalid_active_deadline_seconds, -1}} =
               RunnerPodSpec.new(Map.put(@required_fields, :active_deadline_seconds, -1))

      assert {:error, {:invalid_active_deadline_seconds, "3600"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :active_deadline_seconds, "3600"))

      assert {:error, {:invalid_active_deadline_seconds, nil}} =
               RunnerPodSpec.new(Map.delete(@required_fields, :active_deadline_seconds))
    end

    test "accepts a positive integer" do
      assert {:ok, spec} =
               RunnerPodSpec.new(Map.put(@required_fields, :active_deadline_seconds, 7200))

      assert spec.active_deadline_seconds == 7200
    end
  end

  describe "new/1 — resource quantity validation" do
    test "rejects malformed cpu quantities" do
      assert {:error, {:invalid_cpu_request, "abc"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :cpu_request, "abc"))

      assert {:error, {:invalid_cpu_limit, "1.5Gi"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :cpu_limit, "1.5Gi"))
    end

    test "accepts bare-core and millicore cpu quantities" do
      assert {:ok, spec} =
               RunnerPodSpec.new(Map.put(@required_fields, :cpu_limit, "2"))

      assert spec.cpu_limit == "2"
    end

    test "rejects malformed memory quantities" do
      assert {:error, {:invalid_mem_request, "abc"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :mem_request, "abc"))

      assert {:error, {:invalid_mem_limit, "1Xi"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :mem_limit, "1Xi"))
    end

    test "rejects a non-binary quantity" do
      assert {:error, {:invalid_cpu_request, 100}} =
               RunnerPodSpec.new(Map.put(@required_fields, :cpu_request, 100))
    end
  end

  describe "new/1 — limit must not be below request" do
    test "rejects a cpu_limit below cpu_request" do
      fields =
        @required_fields
        |> Map.put(:cpu_request, "500m")
        |> Map.put(:cpu_limit, "100m")

      assert {:error, {:cpu_limit_below_request, "100m", "500m"}} = RunnerPodSpec.new(fields)
    end

    test "rejects a mem_limit below mem_request" do
      fields =
        @required_fields
        |> Map.put(:mem_request, "768Mi")
        |> Map.put(:mem_limit, "256Mi")

      assert {:error, {:mem_limit_below_request, "256Mi", "768Mi"}} = RunnerPodSpec.new(fields)
    end

    test "accepts a limit exactly equal to the request (boundary)" do
      fields =
        @required_fields
        |> Map.put(:cpu_request, "250m")
        |> Map.put(:cpu_limit, "250m")
        |> Map.put(:mem_request, "512Mi")
        |> Map.put(:mem_limit, "512Mi")

      assert {:ok, _spec} = RunnerPodSpec.new(fields)
    end

    test "compares cpu across bare-core and millicore units correctly" do
      fields =
        @required_fields
        |> Map.put(:cpu_request, "1000m")
        |> Map.put(:cpu_limit, "1")

      assert {:ok, spec} = RunnerPodSpec.new(fields)
      assert spec.cpu_request == "1000m"
      assert spec.cpu_limit == "1"
    end

    test "compares memory across binary and decimal units correctly" do
      # 2Gi (2_147_483_648 bytes) request vs 1000Mi (1_048_576_000 bytes)
      # limit: the limit is smaller once both are normalized to bytes,
      # even though "1000" > "2" as raw numbers.
      fields =
        @required_fields
        |> Map.put(:mem_request, "2Gi")
        |> Map.put(:mem_limit, "1000Mi")

      assert {:error, {:mem_limit_below_request, "1000Mi", "2Gi"}} = RunnerPodSpec.new(fields)
    end
  end

  describe "new/1 — env validation" do
    test "rejects a non-map env" do
      assert {:error, {:invalid_env, "nope"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :env, "nope"))
    end

    test "rejects a non-string env value" do
      assert {:error, {:invalid_env, %{"KEY" => 1}}} =
               RunnerPodSpec.new(Map.put(@required_fields, :env, %{"KEY" => 1}))
    end

    test "rejects an env key that is not a legal identifier" do
      assert {:error, {:invalid_env, %{"1BAD" => "x"}}} =
               RunnerPodSpec.new(Map.put(@required_fields, :env, %{"1BAD" => "x"}))
    end

    test "accepts a well-formed env map" do
      env = %{"ACTIONS_RUNNER_CONTAINER_HOOKS" => "/home/runner/k8s/index.js", "_PRIVATE" => "1"}
      assert {:ok, spec} = RunnerPodSpec.new(Map.put(@required_fields, :env, env))
      assert spec.env == env
    end
  end

  describe "new/1 — labels validation" do
    test "rejects a non-map labels" do
      assert {:error, {:invalid_labels, "nope"}} =
               RunnerPodSpec.new(Map.put(@required_fields, :labels, "nope"))
    end

    test "rejects an invalid label key" do
      assert {:error, {:invalid_labels, %{"" => "x"}}} =
               RunnerPodSpec.new(Map.put(@required_fields, :labels, %{"" => "x"}))
    end

    test "rejects an invalid label value" do
      assert {:error, {:invalid_labels, %{"run" => "bad value with spaces"}}} =
               RunnerPodSpec.new(
                 Map.put(@required_fields, :labels, %{"run" => "bad value with spaces"})
               )
    end

    test "accepts a prefixed label key and an empty label value" do
      labels = %{"app.kubernetes.io/name" => "crest-runner", "run" => ""}
      assert {:ok, spec} = RunnerPodSpec.new(Map.put(@required_fields, :labels, labels))
      assert spec.labels == labels
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire/1 encodes the Kubernetes JSON wire shape (camelCase keys)" do
      assert {:ok, spec} = RunnerPodSpec.new(@required_fields)

      assert RunnerPodSpec.to_wire(spec) == %{
               "activeDeadlineSeconds" => 3600,
               "cpuLimit" => "500m",
               "cpuRequest" => "100m",
               "env" => %{},
               "image" => "ghcr.io/example/runner:2.319.1",
               "labels" => %{},
               "memLimit" => "768Mi",
               "memRequest" => "256Mi",
               "name" => "run-01hz8k3f9x-build",
               "namespace" => "crest-ci-runners",
               "serviceAccount" => "crest-runner"
             }
    end

    test "from_wire/1 decodes the Kubernetes JSON wire shape" do
      wire = %{
        "activeDeadlineSeconds" => 1800,
        "cpuLimit" => "1",
        "cpuRequest" => "200m",
        "env" => %{"FOO" => "bar"},
        "image" => "ghcr.io/example/runner:2.319.1",
        "labels" => %{"run" => "01hz8k3f9x"},
        "memLimit" => "1Gi",
        "memRequest" => "512Mi",
        "name" => "run-01hz8k3f9x-test",
        "namespace" => "crest-ci-runners",
        "serviceAccount" => "crest-runner"
      }

      assert {:ok, spec} = RunnerPodSpec.from_wire(wire)
      assert spec.active_deadline_seconds == 1800
      assert spec.cpu_limit == "1"
      assert spec.cpu_request == "200m"
      assert spec.env == %{"FOO" => "bar"}
      assert spec.labels == %{"run" => "01hz8k3f9x"}
      assert spec.mem_limit == "1Gi"
      assert spec.mem_request == "512Mi"
      assert spec.name == "run-01hz8k3f9x-test"
      assert spec.namespace == "crest-ci-runners"
      assert spec.service_account == "crest-runner"
    end

    test "from_wire/1 applies the laptop profile defaults when resource fields are absent" do
      wire = %{
        "activeDeadlineSeconds" => 900,
        "image" => "ghcr.io/example/runner:2.319.1",
        "name" => "run-01hz8k3f9x-min",
        "namespace" => "crest-ci-runners",
        "serviceAccount" => "crest-runner"
      }

      assert {:ok, spec} = RunnerPodSpec.from_wire(wire)
      assert spec.cpu_request == "100m"
      assert spec.cpu_limit == "500m"
      assert spec.mem_request == "256Mi"
      assert spec.mem_limit == "768Mi"
      assert spec.env == %{}
      assert spec.labels == %{}
    end

    test "round-trips through to_wire/1 and from_wire/1" do
      fields =
        Map.merge(@required_fields, %{
          cpu_request: "250m",
          cpu_limit: "1",
          mem_request: "512Mi",
          mem_limit: "1Gi",
          env: %{"RUNNER_MODE" => "k8s"},
          labels: %{"run" => "01hz8k3f9x"}
        })

      assert {:ok, spec} = RunnerPodSpec.new(fields)
      assert {:ok, round_tripped} = spec |> RunnerPodSpec.to_wire() |> RunnerPodSpec.from_wire()
      assert round_tripped == spec
    end
  end

  describe "Jason.Encoder" do
    test "encodes to the same shape as to_wire/1" do
      assert {:ok, spec} = RunnerPodSpec.new(@required_fields)

      assert {:ok, decoded} = spec |> Jason.encode!() |> Jason.decode()
      assert decoded == RunnerPodSpec.to_wire(spec)
    end
  end
end
