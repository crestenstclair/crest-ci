defmodule CrestCiContract.ReqKubeClient do
  @moduledoc """
  `Req`-based concrete implementation of `CrestCiContract.KubeClient`,
  speaking real Kubernetes REST conventions over HTTP: CRUD on
  `/apis/<group>/<version>/namespaces/<ns>/<plural>` (or, for the core
  group, `/api/<version>/namespaces/<ns>/<plural>`), `PATCH` on the
  `/status` subresource, and `watch` via `?watch=true` chunked
  newline-delimited JSON `WatchEvent`s from a `resourceVersion`. It is the
  adapter used against both `mock_k8s` (in-BEAM slice) and a real
  Kubernetes API server — either speaks the same wire protocol, so no
  branching on target lives here.

  `conn` for this adapter is either a bare base-URL string (e.g.
  `"https://k8s.example.com:6443"`) or a caller-built `Req.Request.t()`
  (usually via `new/2`) carrying the base URL plus any transport options
  (auth headers, TLS, retry policy). This module never constructs its own
  `Req.Request` internally for a live call: every callback receives `conn`
  as a parameter and issues the request against exactly that value, so
  the caller (whatever composes controller/gateway/sim-runner wiring)
  fully owns and injects the connection — a plain string when no extra
  transport configuration is needed, a full `Req.Request.t()` when it is.
  That keeps this adapter itself stateless — nothing here needs to be
  reconstructed after a crash, since no authoritative state is held
  anywhere but the Kubernetes API server on the other end of `conn`.

  ## Error classification

  Every callback maps HTTP status codes onto the domain-meaningful atoms
  `CrestCiContract.KubeClient` declares (`:not_found`, `:already_exists`,
  `:conflict`, `:gone`) rather than leaking raw status codes to callers,
  so a reconciler can pattern-match on outcome without knowing this is an
  HTTP adapter at all — an in-memory test double substitutes for this
  module (LSP) because both return the same shapes.

  `update/4` and `patch_status/6` never retry a lost CAS themselves: a 409
  response is surfaced as `{:error, :conflict}` and it is the caller's job
  to re-read and retry against fresh state. Forcing the write here would
  violate the project's optimistic-concurrency invariant.
  """

  @behaviour CrestCiContract.KubeClient

  alias CrestCiContract.KubeClient

  @typedoc "The `conn` this adapter expects: a base-URL string, or a caller-owned, caller-configured `Req.Request.t()`."
  @type conn :: String.t() | Req.Request.t()

  @watch_ack_timeout_ms 10_000

  @doc """
  Convenience constructor: builds a `Req.Request.t()` with `base_url` set,
  merging any additional `Req.new/1` options (headers, auth, retry policy,
  etc). Purely a factory — every other function in this module accepts an
  already-built `conn` rather than calling this internally, so tests and
  alternate wiring can construct (or mock) the `Req.Request` however they
  need.
  """
  @spec new(String.t(), keyword()) :: conn()
  def new(base_url, opts \\ []) do
    Req.new([base_url: base_url] ++ opts)
  end

  @impl KubeClient
  @spec get(conn(), KubeClient.gvk(), KubeClient.namespace(), KubeClient.name()) ::
          {:ok, KubeClient.object()} | {:error, :not_found | term()}
  def get(conn, gvk, namespace, name) do
    case req_call(conn, :get, object_path(gvk, namespace, name)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec list(conn(), KubeClient.gvk(), KubeClient.namespace(), KubeClient.list_opts()) ::
          {:ok, [KubeClient.object()], KubeClient.continue_token()} | {:error, term()}
  def list(conn, gvk, namespace, opts) do
    case req_call(conn, :get, namespace_path(gvk, namespace), params: list_params(opts)) do
      {:ok, %Req.Response{status: 200, body: %{"items" => items} = body}} ->
        {:ok, items, normalize_continue(get_in(body, ["metadata", "continue"]))}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, [], normalize_continue(get_in(body, ["metadata", "continue"]))}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec create(conn(), KubeClient.gvk(), KubeClient.namespace(), KubeClient.object()) ::
          {:ok, KubeClient.object()} | {:error, :already_exists | term()}
  def create(conn, gvk, namespace, object) do
    case req_call(conn, :post, namespace_path(gvk, namespace), json: object) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :already_exists}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec update(conn(), KubeClient.gvk(), KubeClient.namespace(), KubeClient.object()) ::
          {:ok, KubeClient.object()} | {:error, :conflict | term()}
  def update(conn, gvk, namespace, object) do
    name = get_in(object, ["metadata", "name"])

    case req_call(conn, :put, object_path(gvk, namespace, name), json: object) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :conflict}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec patch_status(
          conn(),
          KubeClient.gvk(),
          KubeClient.namespace(),
          KubeClient.name(),
          status :: map(),
          expected_resource_version :: KubeClient.resource_version()
        ) :: {:ok, KubeClient.object()} | {:error, :conflict | term()}
  def patch_status(conn, gvk, namespace, name, status, expected_resource_version) do
    body = %{"status" => status, "expectedResourceVersion" => expected_resource_version}

    case req_call(conn, :patch, status_path(gvk, namespace, name), json: body) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :conflict}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: http_status, body: response_body}} ->
        {:error, {:unexpected_status, http_status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec delete(conn(), KubeClient.gvk(), KubeClient.namespace(), KubeClient.name()) ::
          :ok | {:error, term()}
  def delete(conn, gvk, namespace, name) do
    case req_call(conn, :delete, object_path(gvk, namespace, name)) do
      {:ok, %Req.Response{status: status}} when status in [200, 202, 204] ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl KubeClient
  @spec watch(
          conn(),
          KubeClient.gvk(),
          KubeClient.namespace(),
          KubeClient.resource_version(),
          KubeClient.watch_callback()
        ) :: {:ok, KubeClient.watch_ref()} | {:error, :gone | term()}
  def watch(conn, gvk, namespace, from_resource_version, callback) do
    url = namespace_path(gvk, namespace)
    caller = self()

    {:ok, watch_pid} =
      Task.start(fn -> run_watch(conn, url, from_resource_version, callback, caller) end)

    receive do
      {:req_kube_client_watch_ack, ^watch_pid, ack} -> ack
    after
      @watch_ack_timeout_ms -> {:error, :timeout}
    end
  end

  @doc """
  Stops a live `watch/5` subscription. `watch_ref` is the pid `watch/5`
  returned; this simply tears down the process running its receive loop
  (and, transitively, its underlying `Req` streaming connection) — there is
  no server-side unsubscribe call to make, mirroring how a real Kubernetes
  watch is just an HTTP connection the client is free to close.
  """
  @spec cancel_watch(KubeClient.watch_ref()) :: :ok
  def cancel_watch(watch_ref) when is_pid(watch_ref) do
    if Process.alive?(watch_ref), do: Process.exit(watch_ref, :shutdown)
    :ok
  end

  # -- watch: request + streaming loop (runs in the spawned watch_pid) ------

  defp run_watch(conn, url, from_rv, callback, caller) do
    params =
      if from_rv in [nil, ""],
        do: [watch: "true"],
        else: [watch: "true", resourceVersion: from_rv]

    case req_call(conn, :get, url, params: params, into: :self) do
      {:ok, %Req.Response{status: 200} = resp} ->
        send(caller, {:req_kube_client_watch_ack, self(), {:ok, self()}})
        stream_watch(resp, callback, "")

      {:ok, %Req.Response{status: 410}} ->
        send(caller, {:req_kube_client_watch_ack, self(), {:error, :gone}})

      {:ok, %Req.Response{status: status, body: body}} ->
        send(
          caller,
          {:req_kube_client_watch_ack, self(), {:error, {:unexpected_status, status, body}}}
        )

      {:error, reason} ->
        send(caller, {:req_kube_client_watch_ack, self(), {:error, reason}})
    end
  end

  defp stream_watch(resp, callback, buffer) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, entries} ->
            {buffer, done?} = consume_entries(entries, callback, buffer)
            unless done?, do: stream_watch(resp, callback, buffer)

          :unknown ->
            stream_watch(resp, callback, buffer)
        end
    end
  end

  defp consume_entries(entries, callback, buffer) do
    Enum.reduce(entries, {buffer, false}, fn
      {:data, data}, {buf, done?} ->
        {consume_lines(buf <> data, callback), done?}

      :done, {buf, _done?} ->
        {buf, true}

      {:error, reason}, {buf, done?} ->
        callback.({:error, reason})
        {buf, done?}
    end)
  end

  defp consume_lines(buffer, callback) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        if line != "", do: callback.(decode_watch_event(line))
        consume_lines(rest, callback)

      [incomplete] ->
        incomplete
    end
  end

  defp decode_watch_event(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = decoded} -> to_watch_event(type, Map.get(decoded, "object", %{}))
      {:ok, decoded} -> {:error, {:invalid_watch_event, decoded}}
      {:error, reason} -> {:error, {:invalid_watch_line, reason}}
    end
  end

  defp to_watch_event(type, object) do
    case type |> to_string() |> String.downcase() do
      "added" -> {:added, object}
      "modified" -> {:modified, object}
      "deleted" -> {:deleted, object}
      "bookmark" -> {:bookmark, get_in(object, ["metadata", "resourceVersion"]) || ""}
      "error" -> {:error, object}
      _other -> {:error, {:unknown_watch_event_type, type}}
    end
  end

  # -- shared response handling ---------------------------------------------

  # Dispatches a request against `conn` regardless of which of the two
  # shapes it is. When `conn` is a bare base-URL string, Req's `base_url`
  # option-merging cannot be used (there is no `Req.Request.t()` to carry
  # it), so the full URL is built by direct string concatenation instead.
  # When `conn` is a `Req.Request.t()`, `path` is passed through as the
  # relative `:url` option and combined with `conn`'s own `base_url` by
  # Req's own request step, exactly as `Req.get(conn, url: path)` would.
  defp req_call(conn, method, path, opts \\ [])

  defp req_call(conn, method, path, opts) when is_binary(conn) do
    Req.request([method: method, url: conn <> path, retry: false] ++ opts)
  end

  defp req_call(%Req.Request{} = conn, method, path, opts) do
    Req.request(conn, [method: method, url: path] ++ opts)
  end

  defp normalize_continue(nil), do: nil
  defp normalize_continue(""), do: nil
  defp normalize_continue(token), do: token

  defp list_params(opts) do
    opts
    |> Keyword.take([:label_selector, :continue, :limit])
    |> Enum.flat_map(fn
      {:label_selector, v} -> [{"labelSelector", v}]
      {:continue, v} -> [{"continue", v}]
      {:limit, v} -> [{"limit", v}]
    end)
  end

  # -- URL construction ------------------------------------------------------

  defp namespace_path({"core", version, kind}, namespace) do
    "/api/#{version}/namespaces/#{namespace}/#{plural(kind)}"
  end

  defp namespace_path({group, version, kind}, namespace) do
    "/apis/#{group}/#{version}/namespaces/#{namespace}/#{plural(kind)}"
  end

  defp object_path(gvk, namespace, name), do: namespace_path(gvk, namespace) <> "/#{name}"
  defp status_path(gvk, namespace, name), do: object_path(gvk, namespace, name) <> "/status"

  defp plural(kind), do: kind |> String.downcase() |> Kernel.<>("s")
end
