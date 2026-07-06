defmodule MockK8s.KubeApiHttp.Router do
  @moduledoc """
  Plug router implementing the Kubernetes REST surface described by the
  `MockK8s.KubeApiHttp` port, backed by a `MockK8s.ResourceStore` and a
  `MockK8s.WatchHub` supplied at mount time via `plug: {Router, store:
  ..., watch_hub: ...}` — never instantiated here. See
  `MockK8s.KubeApiHttp.Server`, which owns wiring both of those in.

  Every handler is a thin translation between an HTTP request and a
  `MockK8s.ResourceStore` / `MockK8s.WatchHub` call: this module holds no
  state of its own, so it can be killed and remounted freely — all
  authoritative state and CAS arbitration live in the store it fronts.

  Routes:

    * CRUD + list: `/apis/{group}/{version}/namespaces/{ns}/{plural}` and,
      for core-group kinds, `/api/v1/namespaces/{ns}/{plural}`
    * the `/status` subresource via `PUT` / `PATCH`
    * `?watch=true` streaming newline-delimited JSON `WatchEvent`s
    * `?limit=&continue=` chunked pagination

  Error bodies are shaped like the Kubernetes `Status` object, with a
  machine-readable `reason` in `AlreadyExists | Conflict | NotFound | Gone`.
  """

  use Plug.Router, copy_opts_to_assign: :deps

  alias MockK8s.{ResourceStore, WatchHub}
  alias MockK8s.KubeApiHttp.Kinds

  plug :match
  plug :dispatch

  # -- ci.crest.dev/v1alpha1, coordination.k8s.io/v1, ... --------------------

  get "/apis/:group/:version/namespaces/:ns/:plural" do
    handle_list(conn, group, version, ns, plural)
  end

  post "/apis/:group/:version/namespaces/:ns/:plural" do
    handle_create(conn, group, version, ns, plural)
  end

  get "/apis/:group/:version/namespaces/:ns/:plural/:name" do
    handle_get(conn, group, version, ns, plural, name)
  end

  put "/apis/:group/:version/namespaces/:ns/:plural/:name" do
    handle_update(conn, group, version, ns, plural, name)
  end

  delete "/apis/:group/:version/namespaces/:ns/:plural/:name" do
    handle_delete(conn, group, version, ns, plural, name)
  end

  put "/apis/:group/:version/namespaces/:ns/:plural/:name/status" do
    handle_patch_status(conn, group, version, ns, plural, name)
  end

  patch "/apis/:group/:version/namespaces/:ns/:plural/:name/status" do
    handle_patch_status(conn, group, version, ns, plural, name)
  end

  # -- core/v1 -----------------------------------------------------------

  get "/api/v1/namespaces/:ns/:plural" do
    handle_list(conn, "core", "v1", ns, plural)
  end

  post "/api/v1/namespaces/:ns/:plural" do
    handle_create(conn, "core", "v1", ns, plural)
  end

  get "/api/v1/namespaces/:ns/:plural/:name" do
    handle_get(conn, "core", "v1", ns, plural, name)
  end

  put "/api/v1/namespaces/:ns/:plural/:name" do
    handle_update(conn, "core", "v1", ns, plural, name)
  end

  delete "/api/v1/namespaces/:ns/:plural/:name" do
    handle_delete(conn, "core", "v1", ns, plural, name)
  end

  put "/api/v1/namespaces/:ns/:plural/:name/status" do
    handle_patch_status(conn, "core", "v1", ns, plural, name)
  end

  patch "/api/v1/namespaces/:ns/:plural/:name/status" do
    handle_patch_status(conn, "core", "v1", ns, plural, name)
  end

  match _ do
    send_status(conn, 404, :not_found, "no matching route")
  end

  # -- handlers ------------------------------------------------------------

  defp handle_list(conn, group, version, ns, plural) do
    conn = fetch_query_params(conn)

    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        gvk = Kinds.gvk(reg)

        if conn.query_params["watch"] == "true" do
          handle_watch(conn, gvk, ns)
        else
          limit = parse_limit(conn.query_params["limit"])
          continue = conn.query_params["continue"]

          {:ok, items, next_continue} =
            ResourceStore.list(store(conn), gvk, ns, limit: limit, continue: continue)

          send_json(conn, 200, %{
            "items" => items,
            "metadata" => %{"continue" => next_continue}
          })
        end
    end
  end

  defp handle_watch(conn, gvk, ns) do
    from_rv = conn.query_params["resourceVersion"]

    case WatchHub.subscribe(watch_hub(conn), %{
           gvk: gvk,
           namespace: ns,
           from_resource_version: from_rv
         }) do
      {:error, :gone} ->
        send_status(conn, 410, :gone, "resourceVersion too old — relist required")

      {:ok, watch_ref} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_chunked(200)
        |> watch_loop(watch_ref)
    end
  end

  defp watch_loop(conn, watch_ref) do
    receive do
      {:watch_event, ^watch_ref, event} ->
        line = Jason.encode!(%{"type" => event.type, "object" => event.object}) <> "\n"

        case chunk(conn, line) do
          {:ok, conn} ->
            watch_loop(conn, watch_ref)

          {:error, _reason} ->
            WatchHub.unsubscribe(watch_hub(conn), watch_ref)
            conn
        end

      {:watch_terminated, ^watch_ref, :overflow} ->
        conn
    after
      30_000 ->
        WatchHub.unsubscribe(watch_hub(conn), watch_ref)
        conn
    end
  end

  defp handle_create(conn, group, version, ns, plural) do
    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        {:ok, body, conn} = read_body(conn)

        object =
          body
          |> Jason.decode!()
          |> Map.put("apiVersion", Kinds.api_version(reg))
          |> Map.put("kind", reg.kind)

        case ResourceStore.create(store(conn), Kinds.gvk(reg), ns, object) do
          {:ok, stamped} ->
            send_json(conn, 201, stamped)

          {:error, :already_exists} ->
            send_status(conn, 409, :already_exists, "object already exists")

          {:error, _reason} ->
            send_status(conn, 422, :invalid, "invalid object")
        end
    end
  end

  defp handle_get(conn, group, version, ns, plural, name) do
    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        case ResourceStore.get(store(conn), Kinds.gvk(reg), ns, name) do
          {:ok, object} -> send_json(conn, 200, object)
          {:error, :not_found} -> send_status(conn, 404, :not_found, "object not found")
        end
    end
  end

  defp handle_update(conn, group, version, ns, plural, name) do
    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        {:ok, body, conn} = read_body(conn)

        object =
          body
          |> Jason.decode!()
          |> Map.put("apiVersion", Kinds.api_version(reg))
          |> Map.put("kind", reg.kind)
          |> Map.update("metadata", %{"name" => name}, &Map.put(&1, "name", name))

        case ResourceStore.update(store(conn), Kinds.gvk(reg), ns, object) do
          {:ok, stamped} ->
            send_json(conn, 200, stamped)

          {:error, :conflict} ->
            send_status(conn, 409, :conflict, "stale resourceVersion")

          {:error, :not_found} ->
            send_status(conn, 404, :not_found, "object not found")

          {:error, _reason} ->
            send_status(conn, 422, :invalid, "invalid object")
        end
    end
  end

  defp handle_delete(conn, group, version, ns, plural, name) do
    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        case ResourceStore.delete(store(conn), Kinds.gvk(reg), ns, name) do
          :ok ->
            send_json(conn, 200, %{
              "kind" => "Status",
              "apiVersion" => "v1",
              "status" => "Success"
            })

          {:error, :not_found} ->
            send_status(conn, 404, :not_found, "object not found")
        end
    end
  end

  defp handle_patch_status(conn, group, version, ns, plural, name) do
    case Kinds.lookup(group, version, plural) do
      {:error, :not_found} ->
        send_status(conn, 404, :not_found, "unknown resource type")

      {:ok, reg} ->
        {:ok, body, conn} = read_body(conn)
        decoded = Jason.decode!(body)
        status = Map.get(decoded, "status", %{})
        expected_rv = Map.get(decoded, "expectedResourceVersion")

        case ResourceStore.patch_status(
               store(conn),
               Kinds.gvk(reg),
               ns,
               name,
               status,
               expected_rv
             ) do
          {:ok, stamped} ->
            send_json(conn, 200, stamped)

          {:error, :conflict} ->
            send_status(conn, 409, :conflict, "stale resourceVersion")

          {:error, :not_found} ->
            send_status(conn, 404, :not_found, "object not found")
        end
    end
  end

  # -- shared plumbing -----------------------------------------------------

  defp store(conn), do: Keyword.fetch!(conn.assigns.deps, :store)
  defp watch_hub(conn), do: Keyword.fetch!(conn.assigns.deps, :watch_hub)

  defp parse_limit(nil), do: nil

  defp parse_limit(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_status(conn, http_status, reason, message) do
    body = %{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "message" => message,
      "reason" => reason_string(reason),
      "code" => http_status
    }

    send_json(conn, http_status, body)
  end

  defp reason_string(:already_exists), do: "AlreadyExists"
  defp reason_string(:conflict), do: "Conflict"
  defp reason_string(:not_found), do: "NotFound"
  defp reason_string(:gone), do: "Gone"
  defp reason_string(:invalid), do: "BadRequest"
  defp reason_string(other) when is_atom(other), do: other |> to_string() |> Macro.camelize()
end
