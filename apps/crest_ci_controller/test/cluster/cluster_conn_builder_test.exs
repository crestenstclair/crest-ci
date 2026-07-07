defmodule CrestCiController.Cluster.ClusterConnBuilderTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Cluster.{ClusterConnBuilder, ClusterCredential}

  @cert """
  -----BEGIN CERTIFICATE-----
  MIIC/zCCAeegAwIBAgIUBeSFnKkID+FUM/pfflnENrUa3j8wDQYJKoZIhvcNAQEL
  BQAwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjA3MDcwMTMxMDlaFw0zNjA3MDQwMTMx
  MDlaMA8xDTALBgNVBAMMBHRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
  AoIBAQDl79Mot5HNu4QBD/ccwY9rxP7MpLek4A4XanfGFaWOrkm/u72omF1uz5YX
  xhubVzUwSX/a0gzT5XJ18vKNmDh5P0/duyQGLs669gdJc2PX1zctohH8/qIxNxfx
  kk46Xgl+MzUX1is0OlS6UqqGZlhMqXGpMR5lnXc4LLgcz/NFs3fjLp698mmtQdFG
  x0zkhHTMjnvEi5Q38+a/NTsxGrnJDFEl8wSUkyfiojdGTQDupQmhzlMlAGsl/KLN
  DpecOkk7t1WjQr4ra6IepYZQFIp+8mUdvtfxS02Dir144v77MPRhJ93ZkjcdaPQ8
  yj9isXyKyD8xz/Sp4yo33EQiNfFLAgMBAAGjUzBRMB0GA1UdDgQWBBRTYvLs8msR
  OJ3arqPf9uYjjSE3NTAfBgNVHSMEGDAWgBRTYvLs8msROJ3arqPf9uYjjSE3NTAP
  BgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCeShNTwnUunH1p3vgt
  XtLpp2H8wR/MZaABOuqjNWaD9fJZP24MNfTwGhQ79QKmWL/RD0WXxp9lAyD6C1sD
  Af87n5jjH8P469e9mZk5poupK+fksNszsQS38VUmCgNoXRu4n7MAQVYeBBXGIMPZ
  aeYZ2lcBioA0G5fgpDkilkHdkvnGtH56dIUB24NPlryJkReDtyCIZ5bCyQPurjmp
  TZUueFW6rAZWi38inBkK0H9pexzRwBZALTQPc8vvuvFF3CraE7XJP3xcuJtvTMzV
  bRhTbWumaIvBOdQ62Fe4LO5rVXiCPUMW9Lz55qICTLwp9WAIs9HSEUTRS4NQxmPG
  yCC1
  -----END CERTIFICATE-----
  """

  @key """
  -----BEGIN PRIVATE KEY-----
  MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDl79Mot5HNu4QB
  D/ccwY9rxP7MpLek4A4XanfGFaWOrkm/u72omF1uz5YXxhubVzUwSX/a0gzT5XJ1
  8vKNmDh5P0/duyQGLs669gdJc2PX1zctohH8/qIxNxfxkk46Xgl+MzUX1is0OlS6
  UqqGZlhMqXGpMR5lnXc4LLgcz/NFs3fjLp698mmtQdFGx0zkhHTMjnvEi5Q38+a/
  NTsxGrnJDFEl8wSUkyfiojdGTQDupQmhzlMlAGsl/KLNDpecOkk7t1WjQr4ra6Ie
  pYZQFIp+8mUdvtfxS02Dir144v77MPRhJ93ZkjcdaPQ8yj9isXyKyD8xz/Sp4yo3
  3EQiNfFLAgMBAAECggEAErfGMb9X0C6enVOGY0HigfxkXZZfGL3gh8lz/J0QgB/y
  AviuhMX6fSXK6x6GasvbmZWyIccNokZAXher5RjqJ/yebMdqNFKlI5UZnMIW86Ai
  bsWNv1GfNHBus4ycb6XuEebrQIh/td21vgEyvoQgVgVJKmPEPLNn3BvP1RCcliTR
  ZalS+X2KS9e2ycQ2BU9jIkzVYz+/ELp7QbbPV7x4mQhfGxM9epnxvu/dj84b7bni
  TWToqKb/H4S9+h3tDvlDLFZUwTCdXrSkvaWZUOphwfAl+GknlrnAI90hnxLGsIYy
  7C1WVk7mCc/KVO4Qh4tadWrYqXxBUx94WTFVoHuIWQKBgQD/FEgrcg95CyGesdJ7
  MB0T3Rj+OqF0V1xfTO2lvw2gN61hARkmUvggS7sC9jKdnjFH9lvZuHWY6WEx6Ctv
  XAiMIS/UnB7z6lqPtMBeNUiFQ220MW9J4r3PwvTYx5Sa5QrYkNcAw2u2ZKeh4+3G
  kzSNdkAC43mFuMh5rI9oaY1IZwKBgQDmxE8TPUY7LwJeXn5OcNJEl1wrViHeNgbn
  KsddeAKfhI9xuuIw5ODUx29EEVq/pTPjGhcoA7Ypl7y4A78QaDLJjQuaMey5cazD
  CFNItbUA2bq6A278MCyFHMy3h2VvZYV7POS6jejfmhnY3M0L84fHQ36uyEWA903d
  9EI22odRfQKBgQD6HOQLHaNIV/7WQZyWR/4rDP/FwK2xizu7Ao5/mA9/SzjJRi9n
  4bEE0d0EsW2+GXBPFKTJnlJI5oX0TqfQYJjM9nmU6qR7HQ9Bm8WIWozKhuxZ5KMv
  +pGN16cHrOLs4qs44QTA7d1/EcFBP2JV9N9x2kI30t7EnQSOMgLIKb9r/wKBgA3w
  t/Iqlm6G1XbL8Idei2U3W4sGpf8ddmdKj0aXNFlckanGJ1naybYw4gjTn47KNQs4
  DUQOjVeP4gefulAMa1z/lz7WWz2Mn2ocu6M9ztRhUsVf5bl4U4grCDbiB/+lu12J
  fSvD3Nh9H6iZFg3txTsFWcbHNGOpDNwmoEVeCCSlAoGBAOL4/3ISF2Y7A3YQB0sL
  GwdM2BptI4i+G+Lxq4TRjmWCSrSX2ETIWQ+PWa9uu4YWKgkRNYNDqHs0FCa6xTL5
  dXZfWF0JK8FBkr+pbrfU0VXhKXQa1U2QJuii+CIJYL1jBIqZxU+DQUqmIRURXoeK
  3XY4ylOe9aH9iujSqp3Aa2YS
  -----END PRIVATE KEY-----
  """

  describe "build/1 — client-cert credentials" do
    test "assembles a Req conn with the cluster base URL, peer-verified TLS, and client-cert transport opts, no auth header" do
      {:ok, credential} =
        ClusterCredential.new(%{
          server: "https://127.0.0.1:6443",
          ca_data: @cert,
          auth_kind: :client_cert,
          client_cert_data: @cert,
          client_key_data: @key
        })

      conn = ClusterConnBuilder.build(credential)

      assert %Req.Request{} = conn
      assert conn.options[:base_url] == "https://127.0.0.1:6443"

      transport_opts = conn.options[:connect_options][:transport_opts]
      assert transport_opts[:verify] == :verify_peer
      assert is_list(transport_opts[:cacerts])
      assert transport_opts[:cert] != nil
      assert {:PrivateKeyInfo, _der} = transport_opts[:key]

      refute Map.has_key?(conn.headers, "authorization")
    end
  end

  describe "build/1 — bearer-token credentials" do
    test "assembles a Req conn carrying an Authorization: Bearer header, no client-cert transport opts" do
      {:ok, credential} =
        ClusterCredential.new(%{
          server: "https://staging.crest-ci.example.com:6443",
          ca_data: @cert,
          auth_kind: :bearer_token,
          token: "staging-secret-token-abc123"
        })

      conn = ClusterConnBuilder.build(credential)

      assert conn.options[:base_url] == "https://staging.crest-ci.example.com:6443"
      assert conn.headers["authorization"] == ["Bearer staging-secret-token-abc123"]

      transport_opts = conn.options[:connect_options][:transport_opts]
      assert transport_opts[:verify] == :verify_peer
      refute Keyword.has_key?(transport_opts, :cert)
      refute Keyword.has_key?(transport_opts, :key)
    end
  end

  describe "build/1 — insecure_skip_tls_verify" do
    test "verify: :verify_none wins regardless of auth_kind, and no CA material is carried" do
      {:ok, credential} =
        ClusterCredential.new(%{
          server: "https://127.0.0.1:6443",
          auth_kind: :bearer_token,
          token: "dev-token",
          insecure_skip_tls_verify: true
        })

      conn = ClusterConnBuilder.build(credential)

      transport_opts = conn.options[:connect_options][:transport_opts]
      assert transport_opts[:verify] == :verify_none
      refute Keyword.has_key?(transport_opts, :cacerts)
    end
  end

  describe "build/1 — absent CA data" do
    test "omits :cacerts entirely rather than crashing when ca_data is empty" do
      {:ok, credential} =
        ClusterCredential.new(%{
          server: "https://127.0.0.1:6443",
          auth_kind: :bearer_token,
          token: "dev-token"
        })

      conn = ClusterConnBuilder.build(credential)

      transport_opts = conn.options[:connect_options][:transport_opts]
      assert transport_opts[:verify] == :verify_peer
      refute Keyword.has_key?(transport_opts, :cacerts)
    end
  end
end
