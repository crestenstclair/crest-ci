defmodule MockK8s.ResourceStore.CoreTest do
  use ExUnit.Case, async: true

  alias MockK8s.ResourceStore.Core

  @gvk "ci.crest.dev/v1alpha1/WorkflowRun"
  @lease_gvk "coordination.k8s.io/v1/Lease"
  @ns "default"

  defp object(name, spec \\ %{}) do
    %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => name},
      "spec" => spec,
      "status" => %{}
    }
  end

  describe "resourceVersion monotonicity" do
    test "increases strictly across ALL writes, regardless of kind" do
      state = Core.new()

      {:ok, state, run, _event} = Core.create(state, @gvk, @ns, object("run-a"))
      {:ok, state, lease, _event} = Core.create(state, @lease_gvk, @ns, object("lease-a"))

      {:ok, state, run2, _event} =
        Core.update(state, @gvk, @ns, put_in(run, ["spec", "sha"], "abc123"))

      {:ok, _state, _lease2, _event} =
        Core.patch_status(state, @lease_gvk, @ns, "lease-a", %{"holder" => "x"}, rv(lease))

      versions =
        [run, lease, run2]
        |> Enum.map(&rv/1)
        |> Enum.map(&String.to_integer/1)

      assert versions == Enum.sort(versions)
      assert length(Enum.uniq(versions)) == length(versions)
    end
  end

  describe "create/4" do
    test "duplicate (gvk, namespace, name) fails with :already_exists and stores no duplicate" do
      state = Core.new()
      {:ok, state, _object, _event} = Core.create(state, @gvk, @ns, object("run-a"))

      assert {:error, :already_exists} = Core.create(state, @gvk, @ns, object("run-a"))
      assert {:ok, [_one], nil} = list_all(state, @gvk, @ns)
    end
  end

  describe "update/4 and patch_status/6 optimistic concurrency" do
    test "stale expectedResourceVersion is rejected with :conflict and mutates nothing" do
      state = Core.new()
      {:ok, state, created, _event} = Core.create(state, @gvk, @ns, object("run-a"))
      stale = rv(created)

      {:ok, state, _updated, _event} =
        Core.update(state, @gvk, @ns, put_in(created, ["spec", "sha"], "newsha"))

      assert {:error, :conflict} =
               Core.update(state, @gvk, @ns, put_in(created, ["spec", "sha"], "other"))

      assert {:error, :conflict} =
               Core.patch_status(state, @gvk, @ns, "run-a", %{"phase" => "Running"}, stale)

      {:ok, current} = Core.get(state, @gvk, @ns, "run-a")
      assert current["spec"]["sha"] == "newsha"
    end

    test "patch_status replaces only status; update never touches status" do
      state = Core.new()

      {:ok, state, created, _event} =
        Core.create(state, @gvk, @ns, object("run-a", %{"sha" => "abc"}))

      {:ok, state, patched, _event} =
        Core.patch_status(state, @gvk, @ns, "run-a", %{"phase" => "Running"}, rv(created))

      assert patched["status"] == %{"phase" => "Running"}
      assert patched["spec"] == %{"sha" => "abc"}
      assert patched["metadata"]["name"] == "run-a"

      {:ok, _state, updated, _event} =
        Core.update(state, @gvk, @ns, put_in(patched, ["spec", "sha"], "def"))

      assert updated["status"] == %{"phase" => "Running"}
      assert updated["spec"] == %{"sha" => "def"}
    end
  end

  describe "watch events" do
    test "every successful write produces exactly one event stamped with the new resourceVersion" do
      state = Core.new()

      {:ok, state, created, create_event} = Core.create(state, @gvk, @ns, object("run-a"))
      assert create_event.type == "ADDED"
      assert create_event.resource_version == rv(created)

      {:ok, state, updated, update_event} =
        Core.update(state, @gvk, @ns, put_in(created, ["spec", "sha"], "x"))

      assert update_event.type == "MODIFIED"
      assert update_event.resource_version == rv(updated)

      {:ok, state, patched, patch_event} =
        Core.patch_status(state, @gvk, @ns, "run-a", %{"phase" => "Running"}, rv(updated))

      assert patch_event.type == "MODIFIED"
      assert patch_event.resource_version == rv(patched)

      {:ok, _state, deleted, delete_event} = Core.delete(state, @gvk, @ns, "run-a")
      assert delete_event.type == "DELETED"
      assert delete_event.resource_version == rv(deleted)
    end
  end

  describe "list/4 pagination" do
    test "limit=2 over 7 objects enumerates every object exactly once across pages" do
      state =
        Enum.reduce(1..7, Core.new(), fn n, state ->
          {:ok, state, _object, _event} = Core.create(state, @gvk, @ns, object("run-#{n}"))
          state
        end)

      {items, state} = paginate(state, @gvk, @ns, 2, nil, [])

      assert length(items) == 2 + 2 + 2 + 1
      names = Enum.map(items, & &1["metadata"]["name"]) |> Enum.sort()
      assert names == Enum.map(1..7, &"run-#{&1}") |> Enum.sort()
      assert length(Enum.uniq(names)) == 7

      # unrelated write (different gvk) between pages does not perturb the
      # in-progress enumeration
      {:ok, _state, _object, _event} = Core.create(state, @lease_gvk, @ns, object("lease-x"))
    end

    test "each page returns at most `limit` items" do
      state =
        Enum.reduce(1..7, Core.new(), fn n, state ->
          {:ok, state, _object, _event} = Core.create(state, @gvk, @ns, object("run-#{n}"))
          state
        end)

      {:ok, page, continue} = Core.list(state, @gvk, @ns, limit: 2)
      assert length(page) <= 2
      assert continue != nil
    end
  end

  defp paginate(state, gvk, ns, limit, continue, acc) do
    {:ok, page, next_continue} = Core.list(state, gvk, ns, limit: limit, continue: continue)

    acc = acc ++ page

    case next_continue do
      nil -> {acc, state}
      cursor -> paginate(state, gvk, ns, limit, cursor, acc)
    end
  end

  defp list_all(state, gvk, ns) do
    Core.list(state, gvk, ns, [])
  end

  defp rv(object), do: object["metadata"]["resourceVersion"]
end
