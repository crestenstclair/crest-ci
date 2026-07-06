defmodule MockK8s.ResourceStoreTest do
  use ExUnit.Case, async: true

  alias MockK8s.ResourceStore

  @gvk "ci.crest.dev/v1alpha1/WorkflowRun"
  @ns "default"

  setup do
    {:ok, server} = ResourceStore.start_link([])
    %{server: server}
  end

  defp object(name, spec \\ %{}) do
    %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => name},
      "spec" => spec,
      "status" => %{}
    }
  end

  test "create then get round-trips the stamped object", %{server: server} do
    assert {:ok, created} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    assert created["metadata"]["resourceVersion"]
    assert {:ok, ^created} = ResourceStore.get(server, @gvk, @ns, "run-a")
  end

  test "duplicate create is rejected and does not clobber the original", %{server: server} do
    assert {:ok, _created} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    assert {:error, :already_exists} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    assert {:ok, [_one], nil} = ResourceStore.list(server, @gvk, @ns)
  end

  test "update with a stale resourceVersion is rejected as :conflict and mutates nothing", %{
    server: server
  } do
    {:ok, created} = ResourceStore.create(server, @gvk, @ns, object("run-a", %{"sha" => "abc"}))

    # a legitimate update against the current resourceVersion succeeds...
    assert {:ok, updated} =
             ResourceStore.update(server, @gvk, @ns, put_in(created, ["spec", "sha"], "newsha"))

    # ...but replaying the ORIGINAL (now stale) resourceVersion is rejected
    # and must not mutate the object that the first update produced.
    assert {:error, :conflict} =
             ResourceStore.update(server, @gvk, @ns, put_in(created, ["spec", "sha"], "zzz"))

    assert {:ok, current} = ResourceStore.get(server, @gvk, @ns, "run-a")
    assert current == updated
    assert current["spec"]["sha"] == "newsha"
  end

  test "patch_status touches only status; a subsequent update leaves status alone", %{
    server: server
  } do
    {:ok, created} = ResourceStore.create(server, @gvk, @ns, object("run-a", %{"sha" => "abc"}))
    rv = created["metadata"]["resourceVersion"]

    assert {:ok, patched} =
             ResourceStore.patch_status(server, @gvk, @ns, "run-a", %{"phase" => "Running"}, rv)

    assert patched["status"] == %{"phase" => "Running"}
    assert patched["spec"] == %{"sha" => "abc"}

    assert {:ok, updated} =
             ResourceStore.update(server, @gvk, @ns, put_in(patched, ["spec", "sha"], "def"))

    assert updated["status"] == %{"phase" => "Running"}
    assert updated["spec"] == %{"sha" => "def"}
  end

  test "delete removes the object and reports :not_found afterwards", %{server: server} do
    {:ok, _created} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    assert :ok = ResourceStore.delete(server, @gvk, @ns, "run-a")
    assert {:error, :not_found} = ResourceStore.get(server, @gvk, @ns, "run-a")
    assert {:error, :not_found} = ResourceStore.delete(server, @gvk, @ns, "run-a")
  end

  test "every successful write notifies subscribers exactly once", %{server: server} do
    :ok = ResourceStore.subscribe(server)

    {:ok, created} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    assert_receive {:resource_written, %{type: "ADDED", resource_version: rv1}}
    assert rv1 == created["metadata"]["resourceVersion"]
    refute_receive {:resource_written, _}, 20

    {:ok, updated} = ResourceStore.update(server, @gvk, @ns, put_in(created, ["spec", "x"], 1))
    assert_receive {:resource_written, %{type: "MODIFIED", resource_version: rv2}}
    assert rv2 == updated["metadata"]["resourceVersion"]
    refute_receive {:resource_written, _}, 20

    :ok = ResourceStore.delete(server, @gvk, @ns, "run-a")
    assert_receive {:resource_written, %{type: "DELETED"}}
    refute_receive {:resource_written, _}, 20
  end

  test "unsubscribe stops delivery", %{server: server} do
    :ok = ResourceStore.subscribe(server)
    :ok = ResourceStore.unsubscribe(server)

    {:ok, _created} = ResourceStore.create(server, @gvk, @ns, object("run-a"))
    refute_receive {:resource_written, _}, 20
  end

  test "paginated list enumerates every object exactly once across pages", %{server: server} do
    for n <- 1..7 do
      {:ok, _created} = ResourceStore.create(server, @gvk, @ns, object("run-#{n}"))
    end

    {items, _final_continue} = drain(server, nil, [])

    assert length(items) == 7
    names = items |> Enum.map(& &1["metadata"]["name"]) |> Enum.uniq() |> Enum.sort()
    assert names == Enum.map(1..7, &"run-#{&1}") |> Enum.sort()
  end

  defp drain(server, continue, acc) do
    {:ok, page, next_continue} =
      ResourceStore.list(server, @gvk, @ns, limit: 2, continue: continue)

    assert length(page) <= 2
    acc = acc ++ page

    case next_continue do
      nil -> {acc, nil}
      cursor -> drain(server, cursor, acc)
    end
  end
end
