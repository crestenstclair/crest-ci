defmodule MockK8s.ConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Cross-component conformance suite proving the store semantics every other
  component in this project (controller, gateway, sim-runner) rests on.

  Every behavior here is exercised end to end through
  `CrestCiContract.ReqKubeClient` — the real `port.Contract.KubeClient`
  adapter every production component uses — driven over real HTTP against
  `MockK8s.KubeApiHttp.Server` on an ephemeral port. Nothing in this suite
  calls `MockK8s.ResourceStore` directly: the client and the server are
  conformance-tested against each other, exactly as controller/gateway
  would exercise them in production.
  """

  alias CrestCiContract.ReqKubeClient, as: Client

  # `mix test`'s default summary in this Elixir/ExUnit version prints
  # "Result: N passed" rather than the classic "N tests, M failures" line
  # that `make conformance`'s mechanical gate greps for. This registers an
  # additional, standard `ExUnit.after_suite/1` callback (a stable public
  # ExUnit API, independent of formatter choice) so the classic-format
  # summary is still emitted alongside the default one — purely an output
  # compatibility shim, it does not change what runs or what passes.
  ExUnit.after_suite(fn stats ->
    IO.puts("\n#{stats.total} tests, #{stats.failures} failures")
  end)

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, store} = MockK8s.ResourceStore.start_link([])
    {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0)
    port = MockK8s.KubeApiHttp.Server.bound_port(server)

    on_exit(fn -> MockK8s.KubeApiHttp.Server.stop(server) end)

    %{conn: "http://127.0.0.1:#{port}", store: store, server: server, port: port}
  end

  test "1: resourceVersions from a sequence of writes are strictly increasing integers across mixed kinds",
       %{conn: conn} do
    {:ok, wfrun} = Client.create(conn, wfrun_gvk(), "default", object("run-a", %{}))
    {:ok, lease} = Client.create(conn, lease_gvk(), "default", object("lease-a", %{}))
    {:ok, job} = Client.create(conn, runnerjob_gvk(), "default", object("job-a", %{}))
    {:ok, wfdef} = Client.create(conn, wfdef_gvk(), "default", object("def-a", %{}))

    rvs = [wfrun, lease, job, wfdef] |> Enum.map(&rv_int/1)

    assert rvs == Enum.sort(rvs),
           "expected strictly increasing resourceVersions, got #{inspect(rvs)}"

    assert Enum.uniq(rvs) == rvs, "resourceVersions must not repeat, got #{inspect(rvs)}"
  end

  test "2: create-then-create returns {:error, :already_exists}", %{conn: conn} do
    assert {:ok, _} = Client.create(conn, wfrun_gvk(), "default", object("dup", %{}))

    assert {:error, :already_exists} =
             Client.create(conn, wfrun_gvk(), "default", object("dup", %{}))

    {:ok, items, _continue} = Client.list(conn, wfrun_gvk(), "default", [])
    assert Enum.count(items, &(&1["metadata"]["name"] == "dup")) == 1
  end

  test "3: patch_status with a stale resourceVersion returns {:error, :conflict} and a follow-up get shows the object unchanged",
       %{conn: conn} do
    {:ok, created} = Client.create(conn, wfrun_gvk(), "default", object("stale", %{"a" => 1}))
    rv1 = rv(created)
    stale_rv = to_string(String.to_integer(rv1) + 999)

    assert {:error, :conflict} =
             Client.patch_status(
               conn,
               wfrun_gvk(),
               "default",
               "stale",
               %{"phase" => "Running"},
               stale_rv
             )

    {:ok, fetched} = Client.get(conn, wfrun_gvk(), "default", "stale")

    assert fetched == created,
           "object must be byte-identical after a rejected conflicting patch_status"
  end

  test "4: patch_status changes status but leaves spec byte-identical", %{conn: conn} do
    {:ok, created} =
      Client.create(conn, wfrun_gvk(), "default", object("patch-me", %{"image" => "nginx"}))

    rv1 = rv(created)

    {:ok, patched} =
      Client.patch_status(
        conn,
        wfrun_gvk(),
        "default",
        "patch-me",
        %{"phase" => "Running"},
        rv1
      )

    assert patched["status"] == %{"phase" => "Running"}
    assert patched["spec"] == created["spec"]
    assert rv(patched) != rv1
  end

  test "5: a watch opened before N writes delivers exactly N events in resourceVersion order",
       %{conn: conn} do
    test_pid = self()

    assert {:ok, _watch_ref} =
             Client.watch(conn, wfrun_gvk(), "default", "0", fn event ->
               send(test_pid, {:watch_event, event})
             end)

    names = for i <- 0..2, do: "watched-#{i}"

    for name <- names do
      {:ok, _} = Client.create(conn, wfrun_gvk(), "default", object(name, %{}))
    end

    events = collect_added_events(3)

    assert length(events) == 3,
           "expected exactly 3 events, got #{length(events)}: #{inspect(events)}"

    observed_names = Enum.map(events, fn {:added, object} -> object["metadata"]["name"] end)
    assert observed_names == names, "watch events must be delivered in write order"

    rvs = Enum.map(events, fn {:added, object} -> rv(object) end)

    assert rvs == Enum.sort_by(rvs, &String.to_integer/1),
           "watch events must be delivered in resourceVersion order, got #{inspect(rvs)}"
  end

  test "6: watch from an expired resourceVersion returns {:error, :gone}", %{store: store} do
    {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0, backlog_limit: 2)
    port = MockK8s.KubeApiHttp.Server.bound_port(server)
    on_exit(fn -> MockK8s.KubeApiHttp.Server.stop(server) end)
    conn = "http://127.0.0.1:#{port}"

    for i <- 0..2 do
      {:ok, _} = Client.create(conn, wfrun_gvk(), "default", object("evict-#{i}", %{}))
    end

    assert {:error, :gone} =
             Client.watch(conn, wfrun_gvk(), "default", "1", fn _event -> :ok end)
  end

  test "7: paginated list with limit 2 over 7 objects yields all 7 exactly once", %{conn: conn} do
    for i <- 0..6 do
      {:ok, _} = Client.create(conn, wfrun_gvk(), "default", object("run-#{i}", %{}))
    end

    {names, page_sizes} = drain_pages(conn, wfrun_gvk(), "default", nil, [], [])

    assert length(names) == 7
    assert Enum.uniq(names) == names, "every object must appear exactly once across pages"
    assert Enum.sort(names) == for(i <- 0..6, do: "run-#{i}")
    assert Enum.all?(page_sizes, &(&1 <= 2)), "no page may exceed the requested limit of 2"
  end

  test "8: two concurrent CAS updates against the same resourceVersion — exactly one succeeds and exactly one conflicts",
       %{conn: conn} do
    {:ok, created} = Client.create(conn, wfrun_gvk(), "default", object("race", %{"n" => 0}))
    rv1 = rv(created)

    results =
      [1, 2]
      |> Enum.map(fn n ->
        Task.async(fn ->
          Client.update(conn, wfrun_gvk(), "default", update_object("race", rv1, %{"n" => n}))
        end)
      end)
      |> Task.await_many(5_000)

    statuses =
      Enum.map(results, fn
        {:ok, _object} -> :ok
        {:error, :conflict} -> :conflict
      end)
      |> Enum.sort()

    assert statuses == [:conflict, :ok],
           "exactly one concurrent CAS update must win and one must lose, got #{inspect(results)}"
  end

  # -- gvk fixtures ----------------------------------------------------------
  # Non-core-group kinds only, so the client exercises the ordinary
  # /apis/{group}/{version}/... path rather than the core-group /api/v1
  # special case.

  defp wfrun_gvk, do: {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  defp wfdef_gvk, do: {"ci.crest.dev", "v1alpha1", "WorkflowDefinition"}
  defp runnerjob_gvk, do: {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  defp lease_gvk, do: {"coordination.k8s.io", "v1", "Lease"}

  # -- object fixtures ---------------------------------------------------

  defp object(name, spec), do: %{"metadata" => %{"name" => name}, "spec" => spec}

  defp update_object(name, resource_version, spec),
    do: %{"metadata" => %{"name" => name, "resourceVersion" => resource_version}, "spec" => spec}

  defp rv(object), do: object["metadata"]["resourceVersion"]
  defp rv_int(object), do: object |> rv() |> String.to_integer()

  # -- helpers -------------------------------------------------------------

  defp drain_pages(conn, gvk, ns, continue, names_acc, sizes_acc) do
    opts = if continue, do: [limit: 2, continue: continue], else: [limit: 2]

    {:ok, items, next_continue} = Client.list(conn, gvk, ns, opts)
    names = Enum.map(items, & &1["metadata"]["name"])

    if next_continue do
      drain_pages(conn, gvk, ns, next_continue, names_acc ++ names, sizes_acc ++ [length(items)])
    else
      {names_acc ++ names, sizes_acc ++ [length(items)]}
    end
  end

  defp collect_added_events(count, acc \\ [])
  defp collect_added_events(0, acc), do: Enum.reverse(acc)

  defp collect_added_events(count, acc) do
    receive do
      {:watch_event, {:added, _object} = event} ->
        collect_added_events(count - 1, [event | acc])

      {:watch_event, _other_event} ->
        collect_added_events(count, acc)
    after
      5_000 -> Enum.reverse(acc)
    end
  end
end
