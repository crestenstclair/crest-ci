defmodule CrestCiController.Cluster.KubeconfigLoaderTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Cluster.KubeconfigLoader

  @ca_data Base.encode64("fake-ca-cert")
  @cert_data Base.encode64("fake-client-cert")
  @key_data Base.encode64("fake-client-key")

  describe "load/2" do
    test "extracts a client-cert credential using current-context when context_name is nil" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
            certificate-authority-data: #{@ca_data}
            insecure-skip-tls-verify: false
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            client-certificate-data: #{@cert_data}
            client-key-data: #{@key_data}
      """

      assert {:ok, credential} = KubeconfigLoader.load(yaml, nil)
      assert credential.server == "https://cluster.example.com:6443"
      assert credential.ca_data == "fake-ca-cert"
      assert credential.auth_kind == :client_cert
      assert credential.client_cert_data == "fake-client-cert"
      assert credential.client_key_data == "fake-client-key"
      assert credential.insecure_skip_tls_verify == false
    end

    test "extracts a bearer-token credential" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
            certificate-authority-data: #{@ca_data}
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            token: fake-bearer-token
      """

      assert {:ok, credential} = KubeconfigLoader.load(yaml, nil)
      assert credential.auth_kind == :bearer_token
      assert credential.token == "fake-bearer-token"
    end

    test "selects an explicit context_name over current-context" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: prod
      clusters:
        - name: dev-cluster
          cluster:
            server: https://dev.example.com:6443
            certificate-authority-data: #{@ca_data}
        - name: prod-cluster
          cluster:
            server: https://prod.example.com:6443
            certificate-authority-data: #{@ca_data}
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
        - name: prod
          context:
            cluster: prod-cluster
            user: prod-user
      users:
        - name: dev-user
          user:
            token: dev-token
        - name: prod-user
          user:
            token: prod-token
      """

      assert {:ok, credential} = KubeconfigLoader.load(yaml, "dev")
      assert credential.server == "https://dev.example.com:6443"
      assert credential.token == "dev-token"
    end

    test "honors insecure-skip-tls-verify: true" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
            insecure-skip-tls-verify: true
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            token: fake-bearer-token
      """

      assert {:ok, credential} = KubeconfigLoader.load(yaml, nil)
      assert credential.insecure_skip_tls_verify == true
    end

    test "returns an error for malformed YAML" do
      assert {:error, :invalid_yaml} = KubeconfigLoader.load("not: [valid: yaml", nil)
    end

    test "returns an error when the document is not a map" do
      assert {:error, :invalid_document} = KubeconfigLoader.load("- 1\n- 2\n", nil)
    end

    test "returns an error when context_name is nil and current-context is absent" do
      yaml = """
      apiVersion: v1
      kind: Config
      clusters: []
      contexts: []
      users: []
      """

      assert {:error, :no_current_context} = KubeconfigLoader.load(yaml, nil)
    end

    test "returns an error when the named context is missing" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            token: dev-token
      """

      assert {:error, {:context_not_found, "missing"}} = KubeconfigLoader.load(yaml, "missing")
    end

    test "returns an error when the context's cluster is missing" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters: []
      contexts:
        - name: dev
          context:
            cluster: ghost-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            token: dev-token
      """

      assert {:error, {:cluster_not_found, "ghost-cluster"}} = KubeconfigLoader.load(yaml, nil)
    end

    test "returns an error when the context's user is missing" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: ghost-user
      users: []
      """

      assert {:error, {:user_not_found, "ghost-user"}} = KubeconfigLoader.load(yaml, nil)
    end

    test "returns an error when the cluster is missing a server" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            certificate-authority-data: #{@ca_data}
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            token: dev-token
      """

      assert {:error, :missing_server} = KubeconfigLoader.load(yaml, nil)
    end

    test "returns an error when the user has no supported auth material" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            exec:
              command: some-external-plugin
      """

      assert {:error, :unsupported_user_auth} = KubeconfigLoader.load(yaml, nil)
    end

    test "does not read client-certificate/client-key file path fields (pure, no I/O)" do
      yaml = """
      apiVersion: v1
      kind: Config
      current-context: dev
      clusters:
        - name: dev-cluster
          cluster:
            server: https://cluster.example.com:6443
      contexts:
        - name: dev
          context:
            cluster: dev-cluster
            user: dev-user
      users:
        - name: dev-user
          user:
            client-certificate: /etc/kubernetes/pki/client.crt
            client-key: /etc/kubernetes/pki/client.key
      """

      assert {:error, :unsupported_user_auth} = KubeconfigLoader.load(yaml, nil)
    end
  end
end
