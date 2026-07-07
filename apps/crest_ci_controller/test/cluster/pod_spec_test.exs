defmodule CrestCiController.Cluster.PodSpecTest do
  @moduledoc """
  Cross-component proof for the `Cluster` context's mix-provable slice
  (D2 §10 / spec/cluster.cue): the kubeconfig -> `ClusterCredential`
  loader, the pure `RunnerJob` -> `RunnerPodSpec` builder, and the
  real-cluster orchestrator driven against a `MockK8s` server.

  Contract assumed for the two collaborators this file exercises but does
  not itself define (`CrestCiController.Cluster.PodSpecBuilder` and
  `CrestCiController.Cluster.RealPodOrchestrator` — see
  `domainService.Cluster.PodSpecBuilder` / `applicationService.Cluster.RealPodOrchestrator`
  in spec/cluster.cue):

    * `PodSpecBuilder.build/1` takes a single fields map —
      `:runner_job` (the decoded RunnerJob wire object), `:image`,
      `:gateway_url`, `:namespace`, `:service_account`,
      `:active_deadline_seconds` (job timeout + slack, computed by the
      caller), and optional `:profile` overrides (the same keys
      `RunnerPodSpec.new/1` accepts: `cpu_request`, `cpu_limit`,
      `mem_request`, `mem_limit`) — and returns
      `{:ok, RunnerPodSpec.t()} | {:error, reason}`. The pod name is the
      RunnerJob's own (already-deterministic) name; labels are copied
      verbatim from the RunnerJob's own metadata labels (its runs-on
      placement selectors); env always carries `GATEWAY_URL` and a
      `CREST_CI_RUNNER_NAME` identity claim purely derived from the given
      inputs. `RunnerPodSpec` itself holds no ownerReference or
      restartPolicy field (see its own moduledoc) — those are the real
      Pod object's concern, added by `RealPodOrchestrator` below, not
      `PodSpecBuilder`'s.

    * `RealPodOrchestrator.reconcile/4` takes `(kube_conn, runner_job_wire,
      namespace, builder_opts)`, builds the `RunnerPodSpec` via
      `PodSpecBuilder`, wraps it into a real Pod wire object — carrying an
      `ownerReference` back to the RunnerJob and `restartPolicy: "Never"`
      (the ephemeral, run-once contract) — and creates it via
      `CrestCiContract.KubeClient.create/4`, treating
      `{:error, :already_exists}` as success so a replayed reconcile is a
      no-op rather than a duplicate.

  Prints exactly one line:
  `pod_specs_built=<n> deterministic=<true|false> duplicate_pods=<n> kubeconfig_contexts=<n>`
  """

  use ExUnit.Case, async: false

  alias CrestCiContract.ReqKubeClient

  alias CrestCiController.Cluster.{
    KubeconfigLoader,
    PodSpecBuilder,
    RealPodOrchestrator,
    RunnerPodSpec
  }

  alias MockK8s.KubeApiHttp.Server, as: MockServer
  alias MockK8s.ResourceStore

  @fixtures_dir Path.join(__DIR__, "fixtures")
  @namespace "crest-ci-runners"
  @pod_gvk {"core", "v1", "Pod"}

  # -- shared summary counters (module-level: on_exit fires once, after
  #    every test in this file has run, regardless of run order) ---------

  setup_all do
    {:ok, counter} =
      Agent.start_link(fn ->
        %{pod_specs_built: 0, deterministic: true, duplicate_pods: 0, kubeconfig_contexts: 0}
      end)

    on_exit(fn ->
      counts = Agent.get(counter, & &1)

      IO.puts(
        "pod_specs_built=#{counts.pod_specs_built} deterministic=#{counts.deterministic} " <>
          "duplicate_pods=#{counts.duplicate_pods} kubeconfig_contexts=#{counts.kubeconfig_contexts}"
      )
    end)

    kubeconfig_yaml = File.read!(Path.join(@fixtures_dir, "kubeconfig.yaml"))
    %{counter: counter, kubeconfig_yaml: kubeconfig_yaml}
  end

  defp bump(counter, key), do: Agent.update(counter, &Map.update!(&1, key, fn n -> n + 1 end))

  defp mark_nondeterministic(counter),
    do: Agent.update(counter, &Map.put(&1, :deterministic, false))

  defp set_duplicate_pods(counter, n), do: Agent.update(counter, &Map.put(&1, :duplicate_pods, n))

  # -- (1) KubeconfigLoader -----------------------------------------------

  describe "KubeconfigLoader" do
    test "extracts server/CA/client-cert auth for the document's current-context",
         %{kubeconfig_yaml: yaml, counter: counter} do
      assert {:ok, credential} = KubeconfigLoader.load(yaml, nil)

      assert credential.server == "https://127.0.0.1:6443"
      assert credential.ca_data == "laptop-ca-data"
      assert credential.auth_kind == :client_cert
      assert credential.client_cert_data == "laptop-cert-data"
      assert credential.client_key_data == "laptop-key-data"
      assert credential.token == ""
      assert credential.insecure_skip_tls_verify == false

      bump(counter, :kubeconfig_contexts)
    end

    test "extracts server/CA/bearer-token auth for a named context",
         %{kubeconfig_yaml: yaml, counter: counter} do
      assert {:ok, credential} = KubeconfigLoader.load(yaml, "staging-token-context")

      assert credential.server == "https://staging.crest-ci.example.com:6443"
      assert credential.ca_data == "staging-ca-data"
      assert credential.auth_kind == :bearer_token
      assert credential.token == "staging-secret-token-abc123"
      assert credential.client_cert_data == ""
      assert credential.client_key_data == ""

      bump(counter, :kubeconfig_contexts)
    end

    test "errors structurally on a context name that is not in the document", %{
      kubeconfig_yaml: yaml
    } do
      assert {:error, {:context_not_found, "does-not-exist"}} =
               KubeconfigLoader.load(yaml, "does-not-exist")
    end
  end

  # -- (2) + (3) PodSpecBuilder --------------------------------------------

  defp sample_runner_job(name) do
    %{
      "metadata" => %{
        "name" => name,
        "uid" => name,
        "labels" => %{
          "crest-ci/runs-on" => "self-hosted",
          "crest-ci/arch" => "x64"
        }
      },
      "spec" => %{
        "jobKey" => "build",
        "runsOn" => ["self-hosted", "x64"],
        "runRef" => "01HZ8K3F9XRUN0000000000000"
      },
      "status" => %{"phase" => "Queued"}
    }
  end

  defp builder_fields(runner_job) do
    %{
      runner_job: runner_job,
      image: "ghcr.io/example/runner:2.319.1",
      gateway_url: "https://gateway.crest-ci.svc:8443",
      namespace: @namespace,
      service_account: "crest-runner",
      active_deadline_seconds: 3600
    }
  end

  describe "PodSpecBuilder" do
    test "pod name == RunnerJob name, runs-on labels copied, GATEWAY_URL + identity in env, ephemeral deadline, laptop resource profile",
         %{counter: counter} do
      runner_job = sample_runner_job("run-01hz8k3f9x-j-build")

      assert {:ok, %RunnerPodSpec{} = pod_spec} = PodSpecBuilder.build(builder_fields(runner_job))

      # pod name == RunnerJob name (deterministic child naming).
      assert pod_spec.name == "run-01hz8k3f9x-j-build"
      assert pod_spec.namespace == @namespace
      assert pod_spec.image == "ghcr.io/example/runner:2.319.1"
      assert pod_spec.service_account == "crest-runner"

      # runs-on labels copied verbatim from the RunnerJob's own metadata.
      assert pod_spec.labels == %{
               "crest-ci/runs-on" => "self-hosted",
               "crest-ci/arch" => "x64"
             }

      # GATEWAY_URL + identity present in env.
      assert pod_spec.env["GATEWAY_URL"] == "https://gateway.crest-ci.svc:8443"
      assert pod_spec.env["CREST_CI_RUNNER_NAME"] == "run-01hz8k3f9x-j-build"

      # ephemeral: activeDeadlineSeconds (restartPolicy-equivalent — see
      # moduledoc: RunnerPodSpec carries no restartPolicy field itself,
      # RealPodOrchestrator sets restartPolicy: "Never" on the real Pod).
      assert pod_spec.active_deadline_seconds == 3600

      # laptop-profile resource requests/limits (D2 §10 defaults).
      assert pod_spec.cpu_request == "100m"
      assert pod_spec.cpu_limit == "500m"
      assert pod_spec.mem_request == "256Mi"
      assert pod_spec.mem_limit == "768Mi"

      bump(counter, :pod_specs_built)
    end

    test "building the same RunnerJob twice yields byte-identical specs", %{counter: counter} do
      runner_job = sample_runner_job("run-01hz8k3f9x-j-test")
      fields = builder_fields(runner_job)

      assert {:ok, spec_a} = PodSpecBuilder.build(fields)
      bump(counter, :pod_specs_built)
      assert {:ok, spec_b} = PodSpecBuilder.build(fields)
      bump(counter, :pod_specs_built)

      wire_a = Jason.encode!(RunnerPodSpec.to_wire(spec_a))
      wire_b = Jason.encode!(RunnerPodSpec.to_wire(spec_b))

      if wire_a == wire_b do
        :ok
      else
        mark_nondeterministic(counter)
      end

      assert wire_a == wire_b
    end
  end

  # -- (4) RealPodOrchestrator, driven against a real MockK8s HTTP server --

  describe "RealPodOrchestrator against MockK8s" do
    setup do
      {:ok, store} = ResourceStore.start_link([])
      {:ok, server} = MockServer.serve(store, 0)
      port = MockServer.bound_port(server)
      conn = ReqKubeClient.new("http://127.0.0.1:#{port}")

      on_exit(fn -> MockServer.stop(server) end)

      %{conn: conn}
    end

    test "creates exactly one Pod per RunnerJob; a second reconcile tolerates 409 and stays at one Pod",
         %{conn: conn, counter: counter} do
      runner_job = sample_runner_job("run-01hz8k3f9x-j-deploy")

      opts = %{
        image: "ghcr.io/example/runner:2.319.1",
        gateway_url: "https://gateway.crest-ci.svc:8443",
        service_account: "crest-runner",
        active_deadline_seconds: 3600
      }

      assert :ok = RealPodOrchestrator.reconcile(conn, runner_job, @namespace, opts)
      bump(counter, :pod_specs_built)

      # Second reconcile of the SAME RunnerJob: deterministic pod name,
      # 409 AlreadyExists tolerated as a no-op — never a duplicate.
      assert :ok = RealPodOrchestrator.reconcile(conn, runner_job, @namespace, opts)

      assert {:ok, pods, _continue} = ReqKubeClient.list(conn, @pod_gvk, @namespace, [])

      matching =
        Enum.filter(pods, fn pod ->
          get_in(pod, ["metadata", "name"]) == "run-01hz8k3f9x-j-deploy"
        end)

      set_duplicate_pods(counter, length(matching) - 1)

      assert length(matching) == 1

      [pod] = matching
      assert get_in(pod, ["metadata", "ownerReferences"]) |> is_list()

      assert Enum.any?(get_in(pod, ["metadata", "ownerReferences"]), fn ref ->
               ref["kind"] == "RunnerJob" and ref["name"] == "run-01hz8k3f9x-j-deploy"
             end)
    end
  end
end
