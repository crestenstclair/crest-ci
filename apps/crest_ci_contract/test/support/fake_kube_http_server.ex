defmodule CrestCiContract.Test.FakeKubeHttpServer do
  @moduledoc """
  Test-only Kubernetes-REST-shaped HTTP fixture for exercising
  `CrestCiContract.ReqKubeClient` over *real* HTTP (real sockets, real JSON
  encoding, real chunked streaming) without depending on the `mock_k8s`
  app. `mock_k8s` itself depends on `crest_ci_contract` — taking a
  dependency the other way, even a test-only one, would create a cyclic
  umbrella dependency. This module is disposable test fixture code, not a
  second production adapter: backed by an `Agent`, started fresh per test,
  torn down on `on_exit`.

  Supports exactly the wire surface `ReqKubeClient` speaks: CRUD plus the
  `/status` subresource under both the grouped (`/apis/<group>/<version>/...`)
  and core (`/api/<version>/...`) path shapes, and `?watch=true` chunked
  newline-delimited-JSON watch events (live dispatch only — no backlog
  replay; `force_gone/1` lets a test simulate a compacted-away
  resourceVersion directly, mirroring how `mock_k8s`'s own fixtures expose
  a `compact_before/2` escape hatch).
  """

  defmodule Router do
    @moduledoc false
    use Plug.Router, copy_opts_to_assign: :deps

    plug(:match)
    plug(:dispatch)

    get "/apis/:group/:version/namespaces/:ns/:plural" do
      handle_list(conn, {group, version, plural}, ns)
    end

    post "/apis/:group/:version/namespaces/:ns/:plural" do
      handle_create(conn, {group, version, plural}, ns)
    end

    get "/apis/:group/:version/namespaces/:ns/:plural/:name" do
      handle_get(conn, {group, version, plural}, ns, name)
    end

    put "/apis/:group/:version/namespaces/:ns/:plural/:name" do
      handle_update(conn, {group, version, plural}, ns, name)
    end

    delete "/apis/:group/:version/namespaces/:ns/:plural/:name" do
      handle_delete(conn, {group, version, plural}, ns, name)
    end

    put "/apis/:group/:version/namespaces/:ns/:plural/:name/status" do
      handle_patch_status(conn, {group, version, plural}, ns, name)
    end

    patch "/apis/:group/:version/namespaces/:ns/:plural/:name/status" do
      handle_patch_status(conn, {group, version, plural}, ns, name)
    end

    get "/api/:version/namespaces/:ns/:plural" do
      handle_list(conn, {"core", version, plural}, ns)
    end

    post "/api/:version/namespaces/:ns/:plural" do
      handle_create(conn, {"core", version, plural}, ns)
    end

    get "/api/:version/namespaces/:ns/:plural/:name" do
      handle_get(conn, {"core", version, plural}, ns, name)
    end

    put "/api/:version/namespaces/:ns/:plural/:name" do
      handle_update(conn, {"core", version, plural}, ns, name)
    end

    delete "/api/:version/namespaces/:ns/:plural/:name" do
      handle_delete(conn, {"core", version, plural}, ns, name)
    end

    put "/api/:version/namespaces/:ns/:plural/:name/status" do
      handle_patch_status(conn, {"core", version, plural}, ns, name)
    end

    patch "/api/:version/namespaces/:ns/:plural/:name/status" do
      handle_patch_status(conn, {"core", version, plural}, ns, name)
    end

    match _ do
      send_status(conn, 404, "NotFound", "no matching route")
    end

    defp handle_list(conn, gvk, ns) do
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["watch"] == "true" do
        handle_watch(conn, gvk, ns)
      else
        {items, next_continue} =
          Agent.get(store(conn), &Map.get(&1.collections, {gvk, ns}, {[], nil}))

        send_json(conn, 200, %{"items" => items, "metadata" => %{"continue" => next_continue}})
      end
    end

    defp handle_watch(conn, gvk, ns) do
      if Agent.get(store(conn), &(&1.compacted_before != nil)) do
        send_status(conn, 410, "Gone", "resourceVersion too old — relist required")
      else
        watch_ref = make_ref()
        # `self()` must be captured here, in the HTTP handler process — the
        # anonymous function below runs *inside* the Agent's own process
        # when passed to `Agent.update/2`, so `self()` there would resolve
        # to the store, not this connection's process.
        watcher = self()
        :ok = Agent.update(store(conn), &subscribe(&1, watch_ref, watcher, gvk, ns))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(200)
        |> watch_loop(watch_ref)
      end
    end

    defp watch_loop(conn, watch_ref) do
      receive do
        {:watch_event, ^watch_ref, type, object} ->
          line = Jason.encode!(%{"type" => type, "object" => object}) <> "\n"

          case Plug.Conn.chunk(conn, line) do
            {:ok, conn} -> watch_loop(conn, watch_ref)
            {:error, _reason} -> conn
          end
      after
        5_000 -> conn
      end
    end

    defp handle_create(conn, gvk, ns) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      object = Jason.decode!(body)
      name = get_in(object, ["metadata", "name"])

      case Agent.get_and_update(store(conn), &create(&1, gvk, ns, name, object)) do
        {:ok, stamped} ->
          send_json(conn, 201, stamped)

        {:error, :already_exists} ->
          send_status(conn, 409, "AlreadyExists", "object already exists")
      end
    end

    defp handle_get(conn, gvk, ns, name) do
      case Agent.get(store(conn), &get_in(&1.objects, [{gvk, ns, name}])) do
        nil -> send_status(conn, 404, "NotFound", "object not found")
        object -> send_json(conn, 200, object)
      end
    end

    defp handle_update(conn, gvk, ns, name) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      object = Jason.decode!(body)

      case Agent.get_and_update(store(conn), &update(&1, gvk, ns, name, object)) do
        {:ok, stamped} -> send_json(conn, 200, stamped)
        {:error, :conflict} -> send_status(conn, 409, "Conflict", "stale resourceVersion")
        {:error, :not_found} -> send_status(conn, 404, "NotFound", "object not found")
      end
    end

    defp handle_delete(conn, gvk, ns, name) do
      case Agent.get_and_update(store(conn), &delete(&1, gvk, ns, name)) do
        :ok -> send_json(conn, 200, %{"kind" => "Status", "status" => "Success"})
        {:error, :not_found} -> send_status(conn, 404, "NotFound", "object not found")
      end
    end

    defp handle_patch_status(conn, gvk, ns, name) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      status = Map.get(decoded, "status", %{})
      expected_rv = Map.get(decoded, "expectedResourceVersion")

      case Agent.get_and_update(
             store(conn),
             &patch_status(&1, gvk, ns, name, status, expected_rv)
           ) do
        {:ok, stamped} -> send_json(conn, 200, stamped)
        {:error, :conflict} -> send_status(conn, 409, "Conflict", "stale resourceVersion")
        {:error, :not_found} -> send_status(conn, 404, "NotFound", "object not found")
      end
    end

    # -- Agent-backed store, keyed by {gvk, ns, name} --------------------

    defp store(conn), do: Keyword.fetch!(conn.assigns.deps, :store)

    defp create(state, gvk, ns, name, object) do
      key = {gvk, ns, name}

      if Map.has_key?(state.objects, key) do
        {{:error, :already_exists}, state}
      else
        next_rv = state.rv + 1
        stamped = put_rv(object, next_rv)
        state = put_object(state, gvk, ns, key, stamped, next_rv)
        broadcast(state, gvk, ns, "ADDED", stamped)
        {{:ok, stamped}, state}
      end
    end

    defp update(state, gvk, ns, name, object) do
      key = {gvk, ns, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, current} ->
          if rv(current) != rv(object) do
            {{:error, :conflict}, state}
          else
            next_rv = state.rv + 1
            stamped = put_rv(object, next_rv)
            state = put_object(state, gvk, ns, key, stamped, next_rv)
            broadcast(state, gvk, ns, "MODIFIED", stamped)
            {{:ok, stamped}, state}
          end
      end
    end

    defp patch_status(state, gvk, ns, name, status, expected_rv) do
      key = {gvk, ns, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, current} ->
          if rv(current) != expected_rv do
            {{:error, :conflict}, state}
          else
            next_rv = state.rv + 1

            stamped =
              current
              |> Map.put("status", status)
              |> put_rv(next_rv)

            state = put_object(state, gvk, ns, key, stamped, next_rv)
            broadcast(state, gvk, ns, "MODIFIED", stamped)
            {{:ok, stamped}, state}
          end
      end
    end

    defp delete(state, gvk, ns, name) do
      key = {gvk, ns, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, object} ->
          objects = Map.delete(state.objects, key)

          items =
            objects |> Enum.filter(&match_collection?(&1, gvk, ns)) |> Enum.map(&elem(&1, 1))

          collections = Map.put(state.collections, {gvk, ns}, {items, nil})
          state = %{state | objects: objects, collections: collections}
          broadcast(state, gvk, ns, "DELETED", object)
          {:ok, state}
      end
    end

    defp put_object(state, gvk, ns, key, stamped, next_rv) do
      objects = Map.put(state.objects, key, stamped)

      items =
        objects |> Enum.filter(&match_collection?(&1, gvk, ns)) |> Enum.map(&elem(&1, 1))

      collections = Map.put(state.collections, {gvk, ns}, {items, nil})
      # `next_rv` is the integer counter; `rv(stamped)` (the stamped
      # `resourceVersion` on the object) is its string wire form — the two
      # must never be compared against each other.
      %{state | objects: objects, collections: collections, rv: next_rv}
    end

    defp match_collection?({{o_gvk, o_ns, _name}, _object}, gvk, ns),
      do: o_gvk == gvk and o_ns == ns

    defp subscribe(state, watch_ref, pid, gvk, ns) do
      %{state | subscribers: [{watch_ref, pid, gvk, ns} | state.subscribers]}
    end

    defp broadcast(state, gvk, ns, type, object) do
      Enum.each(state.subscribers, fn
        {watch_ref, pid, sub_gvk, sub_ns} when sub_gvk == gvk and sub_ns == ns ->
          send(pid, {:watch_event, watch_ref, type, object})

        _other ->
          :ok
      end)
    end

    defp put_rv(object, rv) do
      metadata =
        object |> Map.get("metadata", %{}) |> Map.put("resourceVersion", Integer.to_string(rv))

      Map.put(object, "metadata", metadata)
    end

    defp rv(object), do: get_in(object, ["metadata", "resourceVersion"])

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end

    defp send_status(conn, http_status, reason, message) do
      send_json(conn, http_status, %{
        "kind" => "Status",
        "status" => "Failure",
        "message" => message,
        "reason" => reason,
        "code" => http_status
      })
    end
  end

  @doc "Start a fresh, empty fake store."
  @spec start_link() :: {:ok, pid()}
  def start_link do
    Agent.start_link(fn ->
      %{objects: %{}, collections: %{}, rv: 0, subscribers: [], compacted_before: nil}
    end)
  end

  @doc "Marks the store as compacted, so any subsequent `?watch=true` request gets `410 Gone`."
  @spec force_gone(pid()) :: :ok
  def force_gone(store) do
    Agent.update(store, &%{&1 | compacted_before: 0})
  end

  @doc """
  Boots a real Bandit listener on an ephemeral port, fronting `store`.
  Returns the bandit pid and the bound port. Callers are expected to stop
  the returned pid (e.g. via `on_exit`).
  """
  @spec serve(pid()) :: {:ok, pid(), :inet.port_number()}
  def serve(store) do
    {:ok, bandit} =
      Bandit.start_link(plug: {Router, store: store}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, bandit, port}
  end
end
