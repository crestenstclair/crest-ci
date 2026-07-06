defmodule MockK8s.KubeApiHttpTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Contract tests for the `MockK8s.KubeApiHttp` port, plus end-to-end
  behavioral conformance for its concrete implementation,
  `MockK8s.KubeApiHttp.Server`.

  The first section proves the port is a well-formed Elixir behaviour with
  exactly the callback the design declares, and that a minimal conforming
  implementation can adopt it and be dispatched through generically (i.e.
  any caller can depend on `MockK8s.KubeApiHttp` rather than a concrete
  server module).

  The second section drives `MockK8s.KubeApiHttp.Server` over *real HTTP* on
  an ephemeral port — never by calling `MockK8s.ResourceStore` directly — so
  every route, status code, and error shape the design contract promises is
  exercised through the port's actual public interface.
  """

  describe "behaviour shape" do
    test "declares exactly the serve/2 callback" do
      callbacks = MockK8s.KubeApiHttp.behaviour_info(:callbacks)

      assert {:serve, 2} in callbacks
      assert length(callbacks) == 1
    end

    test "module carries moduledoc documenting the contract" do
      assert {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
               Code.fetch_docs(MockK8s.KubeApiHttp)

      assert moduledoc =~ "serve(store, port)"
    end
  end

  describe "conformance of a minimal implementation" do
    defmodule FakeServer do
      @moduledoc false
      @behaviour MockK8s.KubeApiHttp

      @impl MockK8s.KubeApiHttp
      def serve(_store, _port), do: {:ok, self()}
    end

    defmodule FailingFakeServer do
      @moduledoc false
      @behaviour MockK8s.KubeApiHttp

      @impl MockK8s.KubeApiHttp
      def serve(_store, _port), do: {:error, :already_bound}
    end

    test "a module adopting the behaviour satisfies the {:ok, server} success shape" do
      assert {:ok, server} = FakeServer.serve(:fake_store_ref, 0)
      assert is_pid(server)
    end

    test "a module adopting the behaviour may return {:error, reason} on failure" do
      assert {:error, _reason} = FailingFakeServer.serve(:fake_store_ref, 4000)
    end

    test "callers can dispatch through the behaviour module generically" do
      # Simulates how controller/gateway/test-support code should depend on
      # the port, not a concrete server implementation.
      dispatch = fn implementation, store, port -> implementation.serve(store, port) end

      assert {:ok, _server} = dispatch.(FakeServer, :fake_store_ref, 0)
      assert {:error, _reason} = dispatch.(FailingFakeServer, :fake_store_ref, 4000)
    end
  end

  describe "MockK8s.KubeApiHttp.Server — end-to-end HTTP conformance" do
    setup do
      {:ok, _} = Application.ensure_all_started(:inets)
      {:ok, store} = MockK8s.ResourceStore.start_link([])
      {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0)
      port = MockK8s.KubeApiHttp.Server.bound_port(server)

      on_exit(fn -> MockK8s.KubeApiHttp.Server.stop(server) end)

      %{store: store, server: server, port: port}
    end

    test "resourceVersion increases strictly monotonically across mixed-kind writes", %{
      port: port
    } do
      {201, pod} = http(:post, port, collection_path("pods"), pod_body("web", %{}))

      {201, lease} =
        http(
          :post,
          port,
          group_collection_path("coordination.k8s.io", "v1", "leases"),
          pod_body("l1", %{})
        )

      {201, cm} = http(:post, port, collection_path("configmaps"), pod_body("c1", %{}))

      rvs =
        [pod, lease, cm]
        |> Enum.map(&(&1["metadata"]["resourceVersion"] |> String.to_integer()))

      assert rvs == Enum.sort(rvs)
      assert Enum.uniq(rvs) == rvs
    end

    test "create of an already-existing object is rejected as AlreadyExists and does not duplicate",
         %{port: port} do
      {201, _} = http(:post, port, collection_path("pods"), pod_body("dup", %{}))
      {409, body} = http(:post, port, collection_path("pods"), pod_body("dup", %{}))

      assert body["reason"] == "AlreadyExists"
      assert body["kind"] == "Status"

      {200, %{"items" => items}} = http(:get, port, collection_path("pods"))
      assert Enum.count(items, &(&1["metadata"]["name"] == "dup")) == 1
    end

    test "update with a stale resourceVersion is rejected as Conflict and mutates nothing", %{
      port: port
    } do
      {201, created} = http(:post, port, collection_path("pods"), pod_body("web", %{"a" => 1}))
      rv1 = created["metadata"]["resourceVersion"]

      {200, updated} =
        http(:put, port, object_path("pods", "web"), pod_update_body("web", rv1, %{"a" => 2}))

      rv2 = updated["metadata"]["resourceVersion"]
      assert rv2 != rv1

      {409, body} =
        http(:put, port, object_path("pods", "web"), pod_update_body("web", rv1, %{"a" => 3}))

      assert body["reason"] == "Conflict"

      {200, unchanged} = http(:get, port, object_path("pods", "web"))
      assert unchanged["spec"] == updated["spec"]
      assert unchanged["metadata"]["resourceVersion"] == rv2
    end

    test "PatchStatus replaces only the status subtree; Update never touches status", %{
      port: port
    } do
      {201, created} =
        http(:post, port, collection_path("pods"), pod_body("web", %{"image" => "nginx"}))

      rv1 = created["metadata"]["resourceVersion"]

      {200, patched} =
        http(:put, port, status_path("pods", "web"), %{
          "status" => %{"phase" => "Running"},
          "expectedResourceVersion" => rv1
        })

      assert patched["status"] == %{"phase" => "Running"}
      assert patched["spec"] == created["spec"]
      rv2 = patched["metadata"]["resourceVersion"]
      assert rv2 != rv1

      {200, updated} =
        http(
          :put,
          port,
          object_path("pods", "web"),
          pod_update_body("web", rv2, %{"image" => "nginx:2"})
        )

      assert updated["status"] == patched["status"]
      assert updated["spec"]["image"] == "nginx:2"
    end

    test "delete removes the object; a second delete is NotFound", %{port: port} do
      {201, _} = http(:post, port, collection_path("pods"), pod_body("web", %{}))
      {200, _} = http(:delete, port, object_path("pods", "web"))
      {404, body} = http(:delete, port, object_path("pods", "web"))

      assert body["reason"] == "NotFound"
      {404, _} = http(:get, port, object_path("pods", "web"))
    end

    test "paginated list enumerates every object exactly once across continuation pages", %{
      port: port
    } do
      for i <- 0..6 do
        {201, _} = http(:post, port, collection_path("pods"), pod_body("pod-#{i}", %{}))
      end

      {names, page_sizes} = drain_pages(port, collection_path("pods"), nil, [], [])

      assert length(names) == 7
      assert Enum.uniq(names) == names
      assert Enum.sort(names) == for(i <- 0..6, do: "pod-#{i}")
      assert Enum.all?(page_sizes, &(&1 <= 2))
    end

    test "a watch subscription delivers writes in resourceVersion order", %{port: port} do
      # `Req.get!/2` with `into: :self` returns as soon as the response
      # headers arrive — i.e. once the WatchHub subscription is
      # established — so writes issued right after are guaranteed to be
      # delivered live rather than racing subscription setup.
      resp = start_watch(port, collection_path("pods") <> "?watch=true")

      for i <- 0..2 do
        {201, _} = http(:post, port, collection_path("pods"), pod_body("watched-#{i}", %{}))
      end

      events = collect_watch_events(resp, 3)
      Req.cancel_async_response(resp)

      assert length(events) == 3
      rvs = Enum.map(events, & &1["object"]["metadata"]["resourceVersion"])
      assert rvs == Enum.sort_by(rvs, &String.to_integer/1)
      assert Enum.map(events, & &1["type"]) == ["ADDED", "ADDED", "ADDED"]
    end

    test "watch from a resourceVersion older than the retained backlog is rejected as Gone", %{
      store: store
    } do
      {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0, backlog_limit: 2)
      port = MockK8s.KubeApiHttp.Server.bound_port(server)
      on_exit(fn -> MockK8s.KubeApiHttp.Server.stop(server) end)

      for i <- 0..2 do
        {201, _} = http(:post, port, collection_path("pods"), pod_body("evict-#{i}", %{}))
      end

      {410, body} =
        http(:get, port, collection_path("pods") <> "?watch=true&resourceVersion=1")

      assert body["reason"] == "Gone"
    end

    test "two concurrent CAS updates against the same resourceVersion resolve to one winner",
         %{port: port} do
      {201, created} = http(:post, port, collection_path("pods"), pod_body("race", %{"n" => 0}))
      rv = created["metadata"]["resourceVersion"]

      [t1, t2] =
        for n <- [1, 2] do
          Task.async(fn ->
            http(
              :put,
              port,
              object_path("pods", "race"),
              pod_update_body("race", rv, %{"n" => n})
            )
          end)
        end

      statuses = Task.await_many([t1, t2], 5_000) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert statuses == [200, 409]
    end

    test "error responses across endpoints carry a machine-readable Status reason", %{
      port: port
    } do
      {404, not_found_body} = http(:get, port, object_path("pods", "missing"))
      assert not_found_body["reason"] == "NotFound"
      assert not_found_body["kind"] == "Status"

      {201, _} = http(:post, port, collection_path("pods"), pod_body("dup2", %{}))
      {409, dup_body} = http(:post, port, collection_path("pods"), pod_body("dup2", %{}))
      assert dup_body["reason"] == "AlreadyExists"
    end

    # -- HTTP test helpers ---------------------------------------------------

    defp collection_path(plural, ns \\ "default"), do: "/api/v1/namespaces/#{ns}/#{plural}"

    defp group_collection_path(group, version, plural, ns \\ "default"),
      do: "/apis/#{group}/#{version}/namespaces/#{ns}/#{plural}"

    defp object_path(plural, name, ns \\ "default"),
      do: "/api/v1/namespaces/#{ns}/#{plural}/#{name}"

    defp status_path(plural, name, ns \\ "default"),
      do: object_path(plural, name, ns) <> "/status"

    defp pod_body(name, spec), do: %{"metadata" => %{"name" => name}, "spec" => spec}

    defp pod_update_body(name, rv, spec),
      do: %{"metadata" => %{"name" => name, "resourceVersion" => rv}, "spec" => spec}

    defp http(method, port, path, body \\ nil) do
      url = "http://127.0.0.1:#{port}#{path}"

      opts =
        case body do
          nil -> [method: method, url: url, retry: false]
          _ -> [method: method, url: url, json: body, retry: false]
        end

      resp = Req.request!(opts)
      {resp.status, resp.body}
    end

    defp drain_pages(port, base_path, continue, names_acc, sizes_acc) do
      query = if continue, do: "?limit=2&continue=#{continue}", else: "?limit=2"

      {200, %{"items" => items, "metadata" => %{"continue" => next_continue}}} =
        http(:get, port, base_path <> query)

      names = Enum.map(items, & &1["metadata"]["name"])

      if next_continue do
        drain_pages(
          port,
          base_path,
          next_continue,
          names_acc ++ names,
          sizes_acc ++ [length(items)]
        )
      else
        {names_acc ++ names, sizes_acc ++ [length(items)]}
      end
    end

    defp start_watch(port, path) do
      Req.get!("http://127.0.0.1:#{port}#{path}", into: :self)
    end

    defp collect_watch_events(resp, count, acc \\ []) do
      if length(acc) >= count do
        Enum.take(acc, count)
      else
        receive do
          message ->
            case Req.parse_message(resp, message) do
              {:ok, entries} ->
                new_events =
                  Enum.flat_map(entries, fn
                    {:data, data} ->
                      data
                      |> String.split("\n", trim: true)
                      |> Enum.map(&Jason.decode!/1)

                    _other ->
                      []
                  end)

                collect_watch_events(resp, count, acc ++ new_events)

              {:error, _reason} ->
                acc
            end
        after
          5_000 -> acc
        end
      end
    end
  end
end
