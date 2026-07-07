defmodule CrestCiController.Cluster.ClusterCredential do
  @moduledoc """
  `valueObject.Cluster.ClusterCredential` — resolved connection material
  for one real cluster, extracted from a kubeconfig context by
  `CrestCiController.Cluster.KubeconfigLoader`.

  This is a pure value object: a plain struct with validation and no I/O.
  It never talks to a cluster itself — `CrestCiController.Cluster.ClusterConnBuilder`
  is the single seam that turns a `ClusterCredential` into a `KubeClient`
  conn the `ReqKubeClient` adapter accepts. Keeping credential *shape*
  here and conn *construction* there is what lets kubeconfig extraction
  be tested with zero network and zero real TLS handshake.

  `auth_kind` is a closed enum (`:client_cert | :bearer_token`) — exactly
  one of the two supported kubeconfig user-auth shapes `KubeconfigLoader`
  extracts (inline `client-certificate-data`/`client-key-data`, or a bare
  `token`; `exec`-plugin and file-path credentials are rejected upstream
  by `KubeconfigLoader` before this module ever sees them). `new/1`
  enforces that the auth material matching the declared `auth_kind` is
  actually present, so a `ClusterCredential` can never claim
  `:client_cert` while carrying an empty cert or key, or `:bearer_token`
  while carrying an empty token.

  This project's Cluster-context invariant is that credentials never
  appear in a Pod spec's plain env or in logs — kubeconfig secrets stay
  in the controller's conn. To hold up that invariant even under an
  accidental `IO.inspect/1` or a crash report, this module derives no
  `Jason.Encoder` (it is never a Kubernetes wire object) and ships a
  custom `Inspect` implementation that redacts `token`,
  `client_cert_data`, and `client_key_data`.
  """

  @enforce_keys [:server, :auth_kind]
  defstruct server: nil,
            ca_data: "",
            auth_kind: nil,
            client_cert_data: "",
            client_key_data: "",
            token: "",
            insecure_skip_tls_verify: false

  @type auth_kind :: :client_cert | :bearer_token

  @type t :: %__MODULE__{
          server: String.t(),
          ca_data: String.t(),
          auth_kind: auth_kind(),
          client_cert_data: String.t(),
          client_key_data: String.t(),
          token: String.t(),
          insecure_skip_tls_verify: boolean()
        }

  @type build_error ::
          {:invalid_server, term()}
          | {:invalid_ca_data, term()}
          | {:invalid_auth_kind, term()}
          | {:invalid_client_cert_data, term()}
          | {:invalid_client_key_data, term()}
          | {:invalid_token, term()}
          | {:invalid_insecure_skip_tls_verify, term()}
          | :missing_client_cert_data
          | :missing_client_key_data
          | :missing_token

  @auth_kinds [:client_cert, :bearer_token]

  @doc """
  Builds a new `ClusterCredential` from field values (atom keys).

  `server` and `auth_kind` are required. `ca_data`, `client_cert_data`,
  `client_key_data`, and `token` default to `""`;
  `insecure_skip_tls_verify` defaults to `false`.

  Cross-field validation matches the declared `auth_kind` to its
  required material: `:client_cert` requires both `client_cert_data`
  and `client_key_data` to be non-empty; `:bearer_token` requires
  `token` to be non-empty. Returns `{:error, reason}` on the first
  invalid field or invariant violation rather than building a
  partially-invalid struct.
  """
  @spec new(map()) :: {:ok, t()} | {:error, build_error()}
  def new(fields) when is_map(fields) do
    with {:ok, server} <- validate_server(Map.get(fields, :server)),
         {:ok, ca_data} <- validate_string(Map.get(fields, :ca_data, ""), :invalid_ca_data),
         {:ok, auth_kind} <- validate_auth_kind(Map.get(fields, :auth_kind)),
         {:ok, client_cert_data} <-
           validate_string(Map.get(fields, :client_cert_data, ""), :invalid_client_cert_data),
         {:ok, client_key_data} <-
           validate_string(Map.get(fields, :client_key_data, ""), :invalid_client_key_data),
         {:ok, token} <- validate_string(Map.get(fields, :token, ""), :invalid_token),
         {:ok, insecure_skip_tls_verify} <-
           validate_boolean(Map.get(fields, :insecure_skip_tls_verify, false)),
         :ok <- validate_auth_material(auth_kind, client_cert_data, client_key_data, token) do
      {:ok,
       %__MODULE__{
         server: server,
         ca_data: ca_data,
         auth_kind: auth_kind,
         client_cert_data: client_cert_data,
         client_key_data: client_key_data,
         token: token,
         insecure_skip_tls_verify: insecure_skip_tls_verify
       }}
    end
  end

  @spec validate_server(term()) :: {:ok, String.t()} | {:error, {:invalid_server, term()}}
  defp validate_server(server) when is_binary(server) and server != "", do: {:ok, server}
  defp validate_server(other), do: {:error, {:invalid_server, other}}

  @spec validate_string(term(), atom()) :: {:ok, String.t()} | {:error, {atom(), term()}}
  defp validate_string(value, _tag) when is_binary(value), do: {:ok, value}
  defp validate_string(other, tag), do: {:error, {tag, other}}

  @spec validate_auth_kind(term()) :: {:ok, auth_kind()} | {:error, {:invalid_auth_kind, term()}}
  defp validate_auth_kind(auth_kind) when auth_kind in @auth_kinds, do: {:ok, auth_kind}
  defp validate_auth_kind(other), do: {:error, {:invalid_auth_kind, other}}

  @spec validate_boolean(term()) ::
          {:ok, boolean()} | {:error, {:invalid_insecure_skip_tls_verify, term()}}
  defp validate_boolean(value) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(other), do: {:error, {:invalid_insecure_skip_tls_verify, other}}

  @spec validate_auth_material(auth_kind(), String.t(), String.t(), String.t()) ::
          :ok | {:error, build_error()}
  defp validate_auth_material(:client_cert, "", _client_key_data, _token),
    do: {:error, :missing_client_cert_data}

  defp validate_auth_material(:client_cert, _client_cert_data, "", _token),
    do: {:error, :missing_client_key_data}

  defp validate_auth_material(:client_cert, _client_cert_data, _client_key_data, _token), do: :ok

  defp validate_auth_material(:bearer_token, _client_cert_data, _client_key_data, ""),
    do: {:error, :missing_token}

  defp validate_auth_material(:bearer_token, _client_cert_data, _client_key_data, _token), do: :ok
end

defimpl Inspect, for: CrestCiController.Cluster.ClusterCredential do
  import Inspect.Algebra

  # Redacts every secret-bearing field so this struct can never leak
  # credentials through an accidental IO.inspect/1, a crash report, or a
  # log line — the same "credentials never appear in logs" invariant
  # `CrestCiController.Cluster.RealPodOrchestrator` upholds for env vars.
  def inspect(credential, opts) do
    concat([
      "#ClusterCredential<",
      to_doc(
        %{
          server: credential.server,
          auth_kind: credential.auth_kind,
          insecure_skip_tls_verify: credential.insecure_skip_tls_verify,
          ca_data: redacted(credential.ca_data),
          client_cert_data: redacted(credential.client_cert_data),
          client_key_data: redacted(credential.client_key_data),
          token: redacted(credential.token)
        },
        opts
      ),
      ">"
    ])
  end

  defp redacted(""), do: ""
  defp redacted(_secret), do: "[REDACTED]"
end
