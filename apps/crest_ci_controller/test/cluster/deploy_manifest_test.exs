defmodule CrestCiController.Cluster.DeployManifestTest do
  @moduledoc """
  Parses every `deploy/k8s/*.yaml` manifest and asserts the real-cluster
  control-plane wiring is self-consistent, without ever touching a real
  cluster:

    * both namespaces (`crest-ci-system`, `crest-ci-runners`) exist;
    * the `crest-runner` ServiceAccount and its pod create/watch/exec RBAC
      are scoped to `crest-ci-runners` (never CRDs, Leases, or the system
      namespace) and the controller's ClusterRole covers CRDs/pods/leases;
    * `controller.yaml`'s Deployment runs 3 replicas (leader-elected) and
      `gateway.yaml`'s runs 2 (active-active);
    * the `GATEWAY_URLS` value the controller Deployment supplies — the
      same value `RealPodOrchestrator`/`PodSpecBuilder` forwards, unchanged,
      into every ephemeral runner Pod's env once that domain service
      exists — resolves to the gateway Service's own name in `gateway.yaml`,
      so the two can never silently drift apart.

  This is a structural, no-cluster check: it only parses YAML text. It
  never shells out to kubectl/docker/k3d.
  """

  use ExUnit.Case, async: true

  # apps/crest_ci_controller/test/cluster/deploy_manifest_test.exs -> repo root
  @project_root Path.expand("../../../..", __DIR__)
  @deploy_dir Path.join([@project_root, "deploy", "k8s"])

  @namespaces_path Path.join(@deploy_dir, "namespaces.yaml")
  @rbac_path Path.join(@deploy_dir, "rbac.yaml")
  @controller_path Path.join(@deploy_dir, "controller.yaml")
  @gateway_path Path.join(@deploy_dir, "gateway.yaml")

  @system_namespace "crest-ci-system"
  @runner_namespace "crest-ci-runners"

  describe "deploy/k8s/*.yaml" do
    test "both namespaces are declared" do
      docs = read_all!(@namespaces_path)

      names =
        for %{"kind" => "Namespace"} = doc <- docs do
          doc["metadata"]["name"]
        end

      assert @system_namespace in names,
             "expected Namespace #{@system_namespace} in namespaces.yaml, found #{inspect(names)}"

      assert @runner_namespace in names,
             "expected Namespace #{@runner_namespace} in namespaces.yaml, found #{inspect(names)}"
    end

    test "the crest-runner ServiceAccount and its pod RBAC are scoped to crest-ci-runners, and the controller's ClusterRole covers CRDs/pods/leases" do
      docs = read_all!(@rbac_path)

      service_account =
        Enum.find(docs, fn doc ->
          doc["kind"] == "ServiceAccount" and doc["metadata"]["name"] == "crest-runner"
        end)

      assert service_account, "expected a ServiceAccount named crest-runner in rbac.yaml"
      assert service_account["metadata"]["namespace"] == @runner_namespace

      role =
        Enum.find(docs, fn doc ->
          doc["kind"] == "Role" and doc["metadata"]["namespace"] == @runner_namespace
        end)

      assert role, "expected a namespaced Role scoped to #{@runner_namespace}"

      rules = role["rules"] || []

      pod_rule_present? =
        Enum.any?(rules, fn rule ->
          "" in (rule["apiGroups"] || []) and
            "pods" in (rule["resources"] || []) and
            "create" in (rule["verbs"] || []) and
            "watch" in (rule["verbs"] || [])
        end)

      assert pod_rule_present?,
             "expected a Role rule in #{@runner_namespace} granting pods create+watch"

      exec_rule_present? =
        Enum.any?(rules, fn rule ->
          "" in (rule["apiGroups"] || []) and
            "pods/exec" in (rule["resources"] || []) and
            "create" in (rule["verbs"] || [])
        end)

      assert exec_rule_present?,
             "expected a Role rule in #{@runner_namespace} granting pods/exec create (what container-hooks needs)"

      role_binding =
        Enum.find(docs, fn doc ->
          doc["kind"] == "RoleBinding" and doc["metadata"]["namespace"] == @runner_namespace
        end)

      assert role_binding, "expected a RoleBinding scoped to #{@runner_namespace}"

      role_bound_to_crest_runner? =
        Enum.any?(role_binding["subjects"] || [], fn subject ->
          subject["kind"] == "ServiceAccount" and subject["name"] == "crest-runner"
        end)

      assert role_bound_to_crest_runner?,
             "expected the RoleBinding to bind ServiceAccount crest-runner"

      cluster_role = Enum.find(docs, fn doc -> doc["kind"] == "ClusterRole" end)

      assert cluster_role, "expected the controller's ClusterRole for CRDs/pods/leases"

      cluster_rules = cluster_role["rules"] || []

      assert Enum.any?(cluster_rules, fn rule -> "ci.crest.dev" in (rule["apiGroups"] || []) end),
             "expected the ClusterRole to cover the ci.crest.dev CRD group"

      assert Enum.any?(cluster_rules, fn rule -> "pods" in (rule["resources"] || []) end),
             "expected the ClusterRole to cover pods (for RealPodOrchestrator)"

      assert Enum.any?(cluster_rules, fn rule -> "leases" in (rule["resources"] || []) end),
             "expected the ClusterRole to cover coordination.k8s.io leases (for LeaderElector)"

      cluster_role_binding =
        Enum.find(docs, fn doc -> doc["kind"] == "ClusterRoleBinding" end)

      assert cluster_role_binding,
             "expected a ClusterRoleBinding for the controller's ClusterRole"

      cluster_binding_to_controller_sa? =
        Enum.any?(cluster_role_binding["subjects"] || [], fn subject ->
          subject["kind"] == "ServiceAccount" and subject["namespace"] == @system_namespace
        end)

      assert cluster_binding_to_controller_sa?,
             "expected the ClusterRoleBinding to bind a ServiceAccount in #{@system_namespace}"
    end

    test "controller replicas == 3, gateway replicas == 2, and GATEWAY_URLS resolves to the gateway Service" do
      namespaces_docs = read_all!(@namespaces_path)
      rbac_docs = read_all!(@rbac_path)
      controller_docs = read_all!(@controller_path)
      gateway_docs = read_all!(@gateway_path)

      controller_deployment =
        Enum.find(controller_docs, fn doc -> doc["kind"] == "Deployment" end)

      assert controller_deployment, "expected a Deployment in controller.yaml"

      assert controller_deployment["spec"]["replicas"] == 3,
             "expected controller.yaml Deployment to run 3 replicas (leader-elected HA)"

      assert controller_deployment["metadata"]["namespace"] == @system_namespace

      gateway_deployment =
        Enum.find(gateway_docs, fn doc -> doc["kind"] == "Deployment" end)

      assert gateway_deployment, "expected a Deployment in gateway.yaml"

      assert gateway_deployment["spec"]["replicas"] == 2,
             "expected gateway.yaml Deployment to run 2 replicas (active-active)"

      gateway_service = Enum.find(gateway_docs, fn doc -> doc["kind"] == "Service" end)

      assert gateway_service, "expected a Service in gateway.yaml"

      service_name = gateway_service["metadata"]["name"]

      assert is_binary(service_name) and service_name != ""

      gateway_urls_value = env_value(controller_deployment, "GATEWAY_URLS")

      assert is_binary(gateway_urls_value) and gateway_urls_value != "",
             "expected controller.yaml's Deployment to set env GATEWAY_URLS"

      # The host embedded in GATEWAY_URLS must be the gateway Service's own
      # name/DNS — this is the exact value PodSpecBuilder will forward,
      # unchanged, into every ephemeral runner Pod's env once that domain
      # service exists. Checking it here, against the real Service object
      # this asset also owns, keeps the two from drifting silently instead
      # of waiting for a not-yet-generated domain service to catch it.
      gateway_service_matches = String.contains?(gateway_urls_value, service_name)

      manifests =
        length(namespaces_docs) + length(rbac_docs) + length(controller_docs) +
          length(gateway_docs)

      IO.puts("manifests=#{manifests} gateway_service_matches=#{gateway_service_matches}")

      assert gateway_service_matches,
             "expected GATEWAY_URLS (#{inspect(gateway_urls_value)}) to reference the gateway Service name #{inspect(service_name)}"
    end
  end

  defp env_value(deployment, name) do
    deployment
    |> get_in(["spec", "template", "spec", "containers"])
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> nil
      container -> Enum.find(container["env"] || [], fn entry -> entry["name"] == name end)
    end
    |> case do
      nil -> nil
      entry -> entry["value"]
    end
  end

  defp read_all!(path) do
    assert File.exists?(path), "expected #{path} to exist"
    YamlElixir.read_all_from_file!(path)
  end
end
