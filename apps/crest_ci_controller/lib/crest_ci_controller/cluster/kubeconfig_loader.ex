defmodule CrestCiController.Cluster.KubeconfigLoader do
  @moduledoc """
  Extracts a `ClusterCredential` from a kubeconfig YAML document.

  This is a pure function over its two inputs — the kubeconfig YAML
  string and an optional context name — and does no I/O of its own. It
  does not read files, does not resolve `~`-paths, and does not shell
  out to any `exec`-style credential plugin: kubeconfig fields that
  reference external files or executables (`certificate-authority`,
  `client-certificate`, `client-key`, `exec`) are treated as
  unsupported, because honoring them would require filesystem or
  process access this module must not have. Only the inline,
  base64-encoded `*-data` fields and an inline `token` are read.

  The caller passes in the raw kubeconfig text (however it was
  obtained — from a file, a Secret, an env var) and, optionally, which
  context to load; `nil` means "use `current-context` from the
  document itself". This module then walks `contexts` → `clusters` /
  `users` to assemble one `ClusterCredential` for that context.

  A malformed document or a named context/cluster/user that cannot be
  found is a structured `{:error, reason}` — never an exception — so
  callers (e.g. the reconciler) can pattern-match and report a precise
  diagnosis instead of crashing on attacker- or operator-supplied YAML.
  """

  alias CrestCiController.Cluster.ClusterCredential

  @type load_error ::
          :invalid_yaml
          | :invalid_document
          | :no_current_context
          | {:context_not_found, String.t()}
          | :invalid_context
          | {:cluster_not_found, String.t()}
          | :invalid_cluster
          | :missing_server
          | {:user_not_found, String.t()}
          | :invalid_user
          | :unsupported_user_auth
          | {:invalid_credential, term()}

  @doc """
  Loads a `ClusterCredential` for one context out of a kubeconfig YAML
  document.

  `context_name` selects which `contexts` entry to use; `nil` means
  "use the document's `current-context`". Returns `{:error, reason}`
  for any parse failure, missing reference, or unsupported auth method
  (e.g. `exec` or file-path credential fields) rather than raising.
  """
  @spec load(String.t(), String.t() | nil) ::
          {:ok, ClusterCredential.t()} | {:error, load_error()}
  def load(kubeconfig_yaml, context_name \\ nil) when is_binary(kubeconfig_yaml) do
    with {:ok, document} <- parse_yaml(kubeconfig_yaml),
         {:ok, document} <- validate_document(document),
         {:ok, resolved_context_name} <- resolve_context_name(document, context_name),
         {:ok, context} <- find_context(document, resolved_context_name),
         {:ok, cluster_name, user_name} <- context_refs(context),
         {:ok, cluster} <- find_cluster(document, cluster_name),
         {:ok, user} <- find_user(document, user_name),
         {:ok, server} <- cluster_server(cluster),
         ca_data <- decoded_base64(cluster, "certificate-authority-data"),
         insecure_skip_tls_verify <- Map.get(cluster, "insecure-skip-tls-verify", false),
         {:ok, auth_fields} <- user_auth_fields(user) do
      ClusterCredential.new(
        Map.merge(
          %{
            server: server,
            ca_data: ca_data || "",
            insecure_skip_tls_verify: insecure_skip_tls_verify == true
          },
          auth_fields
        )
      )
      |> normalize_credential_error()
    end
  end

  @spec parse_yaml(String.t()) :: {:ok, term()} | {:error, :invalid_yaml}
  defp parse_yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, :invalid_yaml}
    end
  end

  @spec validate_document(term()) :: {:ok, map()} | {:error, :invalid_document}
  defp validate_document(%{} = document), do: {:ok, document}
  defp validate_document(_other), do: {:error, :invalid_document}

  @spec resolve_context_name(map(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_current_context}
  defp resolve_context_name(_document, context_name) when is_binary(context_name),
    do: {:ok, context_name}

  defp resolve_context_name(document, nil) do
    case Map.get(document, "current-context") do
      current when is_binary(current) and current != "" -> {:ok, current}
      _other -> {:error, :no_current_context}
    end
  end

  @spec find_context(map(), String.t()) ::
          {:ok, map()} | {:error, {:context_not_found, String.t()} | :invalid_context}
  defp find_context(document, name) do
    with {:ok, entry} <- find_named(Map.get(document, "contexts"), name, :context_not_found) do
      case Map.get(entry, "context") do
        %{} = context -> {:ok, context}
        _other -> {:error, :invalid_context}
      end
    end
  end

  @spec context_refs(map()) :: {:ok, String.t(), String.t()} | {:error, :invalid_context}
  defp context_refs(context) do
    with cluster_name when is_binary(cluster_name) <- Map.get(context, "cluster"),
         user_name when is_binary(user_name) <- Map.get(context, "user") do
      {:ok, cluster_name, user_name}
    else
      _other -> {:error, :invalid_context}
    end
  end

  @spec find_cluster(map(), String.t()) ::
          {:ok, map()} | {:error, {:cluster_not_found, String.t()} | :invalid_cluster}
  defp find_cluster(document, name) do
    with {:ok, entry} <- find_named(Map.get(document, "clusters"), name, :cluster_not_found) do
      case Map.get(entry, "cluster") do
        %{} = cluster -> {:ok, cluster}
        _other -> {:error, :invalid_cluster}
      end
    end
  end

  @spec find_user(map(), String.t()) ::
          {:ok, map()} | {:error, {:user_not_found, String.t()} | :invalid_user}
  defp find_user(document, name) do
    with {:ok, entry} <- find_named(Map.get(document, "users"), name, :user_not_found) do
      case Map.get(entry, "user") do
        %{} = user -> {:ok, user}
        _other -> {:error, :invalid_user}
      end
    end
  end

  @spec find_named(term(), String.t(), atom()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  defp find_named(entries, name, not_found_tag) when is_list(entries) do
    case Enum.find(entries, fn
           %{"name" => ^name} -> true
           _other -> false
         end) do
      %{} = entry -> {:ok, entry}
      nil -> {:error, {not_found_tag, name}}
    end
  end

  defp find_named(_other, name, not_found_tag), do: {:error, {not_found_tag, name}}

  @spec cluster_server(map()) :: {:ok, String.t()} | {:error, :missing_server}
  defp cluster_server(cluster) do
    case Map.get(cluster, "server") do
      server when is_binary(server) and server != "" -> {:ok, server}
      _other -> {:error, :missing_server}
    end
  end

  @spec decoded_base64(map(), String.t()) :: String.t() | nil
  defp decoded_base64(map, key) do
    with value when is_binary(value) <- Map.get(map, key),
         {:ok, decoded} <- Base.decode64(value) do
      decoded
    else
      _other -> nil
    end
  end

  # Only inline, in-document credential material is supported:
  # `client-certificate-data` + `client-key-data`, or a bare `token`.
  # File-path fields (`client-certificate`, `client-key`) and `exec`
  # plugins require I/O this pure function must not perform, so a user
  # entry that relies on them is rejected as unsupported rather than
  # silently ignored.
  @spec user_auth_fields(map()) :: {:ok, map()} | {:error, :unsupported_user_auth}
  defp user_auth_fields(user) do
    cert_data = decoded_base64(user, "client-certificate-data")
    key_data = decoded_base64(user, "client-key-data")
    token = Map.get(user, "token")

    cond do
      is_binary(cert_data) and is_binary(key_data) ->
        {:ok,
         %{
           auth_kind: :client_cert,
           client_cert_data: cert_data,
           client_key_data: key_data,
           token: ""
         }}

      is_binary(token) and token != "" ->
        {:ok,
         %{auth_kind: :bearer_token, token: token, client_cert_data: "", client_key_data: ""}}

      true ->
        {:error, :unsupported_user_auth}
    end
  end

  @spec normalize_credential_error({:ok, ClusterCredential.t()} | {:error, term()}) ::
          {:ok, ClusterCredential.t()} | {:error, load_error()}
  defp normalize_credential_error({:ok, credential}), do: {:ok, credential}
  defp normalize_credential_error({:error, reason}), do: {:error, {:invalid_credential, reason}}
end
