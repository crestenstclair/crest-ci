defmodule CrestCiController.Cluster.ClusterCredentialTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Cluster.ClusterCredential

  describe "new/1 — client-cert credentials" do
    test "builds a ClusterCredential with client-cert auth material" do
      assert {:ok, credential} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 ca_data: "fake-ca-cert",
                 auth_kind: :client_cert,
                 client_cert_data: "fake-client-cert",
                 client_key_data: "fake-client-key"
               })

      assert credential.server == "https://cluster.example.com:6443"
      assert credential.ca_data == "fake-ca-cert"
      assert credential.auth_kind == :client_cert
      assert credential.client_cert_data == "fake-client-cert"
      assert credential.client_key_data == "fake-client-key"
      assert credential.token == ""
      assert credential.insecure_skip_tls_verify == false
    end

    test "rejects :client_cert with an empty client_cert_data" do
      assert {:error, :missing_client_cert_data} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :client_cert,
                 client_cert_data: "",
                 client_key_data: "fake-client-key"
               })
    end

    test "rejects :client_cert with an empty client_key_data" do
      assert {:error, :missing_client_key_data} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :client_cert,
                 client_cert_data: "fake-client-cert",
                 client_key_data: ""
               })
    end
  end

  describe "new/1 — bearer-token credentials" do
    test "builds a ClusterCredential with bearer-token auth material" do
      assert {:ok, credential} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :bearer_token,
                 token: "fake-bearer-token"
               })

      assert credential.auth_kind == :bearer_token
      assert credential.token == "fake-bearer-token"
      assert credential.client_cert_data == ""
      assert credential.client_key_data == ""
    end

    test "rejects :bearer_token with an empty token" do
      assert {:error, :missing_token} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :bearer_token,
                 token: ""
               })
    end
  end

  describe "new/1 — field validation" do
    test "rejects a missing/empty server" do
      assert {:error, {:invalid_server, nil}} =
               ClusterCredential.new(%{auth_kind: :bearer_token, token: "t"})

      assert {:error, {:invalid_server, ""}} =
               ClusterCredential.new(%{server: "", auth_kind: :bearer_token, token: "t"})
    end

    test "rejects an unknown auth_kind" do
      assert {:error, {:invalid_auth_kind, :ssh_key}} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :ssh_key
               })
    end

    test "honors insecure_skip_tls_verify: true" do
      assert {:ok, credential} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :bearer_token,
                 token: "t",
                 insecure_skip_tls_verify: true
               })

      assert credential.insecure_skip_tls_verify == true
    end
  end

  describe "Inspect — secret redaction" do
    test "never renders token/client_cert_data/client_key_data in plain text" do
      assert {:ok, credential} =
               ClusterCredential.new(%{
                 server: "https://cluster.example.com:6443",
                 auth_kind: :client_cert,
                 client_cert_data: "super-secret-cert",
                 client_key_data: "super-secret-key",
                 token: "super-secret-token"
               })

      rendered = inspect(credential)

      refute rendered =~ "super-secret-cert"
      refute rendered =~ "super-secret-key"
      refute rendered =~ "super-secret-token"
      assert rendered =~ "REDACTED"
      assert rendered =~ "https://cluster.example.com:6443"
    end
  end
end
