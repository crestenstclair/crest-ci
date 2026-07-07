defmodule CrestCiController.Cluster.ClusterConnBuilder do
  @moduledoc """
  Turns a `CrestCiController.Cluster.ClusterCredential` (as extracted by
  `CrestCiController.Cluster.KubeconfigLoader`) into the `conn`
  `CrestCiContract.ReqKubeClient` accepts: a `Req.Request.t()` carrying
  the cluster's base URL plus whatever transport options make the
  request actually authenticate against a live API server.

  This is the single seam where real-cluster TLS and auth enter the
  system — an in-BEAM/mock-k8s conn is just a bare base-URL string with
  no TLS at all (see `CrestCiContract.ReqKubeClient`'s own moduledoc),
  so a malformed or hostile kubeconfig can never reach, let alone
  affect, the mock-cluster test path; only code that explicitly calls
  this module touches real TLS.

  `insecure_skip_tls_verify: true` always wins and maps onto
  `verify: :verify_none`, regardless of `auth_kind` — the operator
  asked to skip verification, so there is no CA material left to trust
  or ignore. Otherwise the credential's own `ca_data` (when present)
  backs `verify: :verify_peer`; the two supported `auth_kind`s are
  mutually exclusive (`ClusterCredential.new/1` already enforces this),
  so exactly one of client-cert transport options or a bearer
  `Authorization` header is ever produced for one conn — never both.

  Never inspects or logs `credential` itself — this module only reads
  its fields to build transport options and headers; it relies on
  `ClusterCredential`'s own redacting `Inspect` implementation as a
  second line of defense should a caller `inspect/1` it anyway, but
  never does so here itself.
  """

  alias CrestCiController.Cluster.ClusterCredential
  alias CrestCiContract.ReqKubeClient

  @doc """
  Builds a `ReqKubeClient` conn (a `Req.Request.t()`) from a
  `ClusterCredential`.

  Always succeeds for a validly-constructed `ClusterCredential` — its
  own `new/1` already enforces that the auth material matching the
  declared `auth_kind` is present, which is the only precondition this
  module depends on.
  """
  @spec build(ClusterCredential.t()) :: ReqKubeClient.conn()
  def build(%ClusterCredential{} = credential) do
    ReqKubeClient.new(credential.server,
      connect_options: [transport_opts: transport_opts(credential)],
      headers: auth_headers(credential)
    )
  end

  # -- TLS transport options ---------------------------------------------

  defp transport_opts(%ClusterCredential{insecure_skip_tls_verify: true}) do
    [verify: :verify_none]
  end

  defp transport_opts(%ClusterCredential{auth_kind: :client_cert} = credential) do
    [verify: :verify_peer]
    |> put_if_present(:cacerts, decoded_ca_certs(credential.ca_data))
    |> put_if_present(:cert, decoded_der(credential.client_cert_data))
    |> put_if_present(:key, decoded_key(credential.client_key_data))
  end

  defp transport_opts(%ClusterCredential{} = credential) do
    [verify: :verify_peer]
    |> put_if_present(:cacerts, decoded_ca_certs(credential.ca_data))
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp decoded_ca_certs(""), do: nil

  defp decoded_ca_certs(pem) do
    case :public_key.pem_decode(pem) do
      [] -> nil
      entries -> Enum.map(entries, fn {_type, der, _cipher_info} -> der end)
    end
  end

  defp decoded_der(""), do: nil

  defp decoded_der(pem) do
    case :public_key.pem_decode(pem) do
      [{_type, der, _cipher_info} | _rest] -> der
      [] -> nil
    end
  end

  defp decoded_key(""), do: nil

  defp decoded_key(pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, _cipher_info} | _rest] -> {type, der}
      [] -> nil
    end
  end

  # -- auth header (bearer-token credentials only) -----------------------

  defp auth_headers(%ClusterCredential{auth_kind: :bearer_token, token: token}) do
    [{"authorization", "Bearer " <> token}]
  end

  defp auth_headers(%ClusterCredential{}), do: []
end
