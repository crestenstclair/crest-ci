defmodule CrestCiContract.KubeClientTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.Test.FakeKubeClient

  @gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  setup do
    {:ok, conn} = FakeKubeClient.start_link()
    %{conn: conn}
  end

  describe "get/4" do
    test "returns {:error, :not_found} for an absent name, distinguishable from other errors", %{
      conn: conn
    } do
      assert {:error, :not_found} = FakeKubeClient.get(conn, @gvk, @namespace, "missing")
    end

    test "returns {:ok, object} once created", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-1"}, "spec" => %{}}
      assert {:ok, created} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      assert {:ok, ^created} = FakeKubeClient.get(conn, @gvk, @namespace, "run-1")
    end
  end

  describe "create/4" do
    test "returns {:error, :already_exists} on a deterministic-name collision", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-1-j-build"}, "spec" => %{}}
      assert {:ok, _} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      assert {:error, :already_exists} = FakeKubeClient.create(conn, @gvk, @namespace, object)
    end

    test "re-issuing create after :already_exists produces no duplicate child (idempotent reconciliation)",
         %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-1-j-build"}, "spec" => %{}}
      assert {:ok, _} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      assert {:error, :already_exists} = FakeKubeClient.create(conn, @gvk, @namespace, object)

      assert {:ok, [only_one], nil} = FakeKubeClient.list(conn, @gvk, @namespace, [])
      assert only_one["metadata"]["name"] == "run-1-j-build"
    end
  end

  describe "update/4" do
    test "returns {:error, :conflict} on a stale resourceVersion and never forces the write", %{
      conn: conn
    } do
      object = %{"metadata" => %{"name" => "run-2"}, "spec" => %{"a" => 1}}
      {:ok, created} = FakeKubeClient.create(conn, @gvk, @namespace, object)

      stale = put_in(created, ["spec", "a"], 2)

      # Someone else updates first, advancing the resourceVersion.
      {:ok, _current} = FakeKubeClient.update(conn, @gvk, @namespace, created)

      assert {:error, :conflict} = FakeKubeClient.update(conn, @gvk, @namespace, stale)

      # The stale writer's value must not have been forced onto the store.
      {:ok, after_conflict} = FakeKubeClient.get(conn, @gvk, @namespace, "run-2")
      refute after_conflict["spec"]["a"] == 2
    end

    test "succeeds against the current resourceVersion", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-3"}, "spec" => %{"a" => 1}}
      {:ok, created} = FakeKubeClient.create(conn, @gvk, @namespace, object)

      updated = put_in(created, ["spec", "a"], 2)
      assert {:ok, result} = FakeKubeClient.update(conn, @gvk, @namespace, updated)
      assert result["spec"]["a"] == 2
    end
  end

  describe "patch_status/6" do
    test "returns {:error, :conflict} on a stale expected_resource_version and never forces the write",
         %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-4"}, "spec" => %{}}
      {:ok, created} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      stale_rv = created["metadata"]["resourceVersion"]

      # Someone else advances the resourceVersion via update.
      {:ok, _current} = FakeKubeClient.update(conn, @gvk, @namespace, created)

      assert {:error, :conflict} =
               FakeKubeClient.patch_status(
                 conn,
                 @gvk,
                 @namespace,
                 "run-4",
                 %{"phase" => "Queued"},
                 stale_rv
               )

      {:ok, current} = FakeKubeClient.get(conn, @gvk, @namespace, "run-4")
      refute current["status"] == %{"phase" => "Queued"}
    end

    test "succeeds when expected_resource_version matches the live one", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-5"}, "spec" => %{}}
      {:ok, created} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      rv = created["metadata"]["resourceVersion"]

      assert {:ok, result} =
               FakeKubeClient.patch_status(
                 conn,
                 @gvk,
                 @namespace,
                 "run-5",
                 %{"phase" => "Queued"},
                 rv
               )

      assert result["status"] == %{"phase" => "Queued"}
    end
  end

  describe "watch/5" do
    test "returns {:error, :gone} for a compacted-away resourceVersion", %{conn: conn} do
      FakeKubeClient.compact_before(conn, 10)
      assert {:error, :gone} = FakeKubeClient.watch(conn, @gvk, @namespace, "3", fn _ -> :ok end)
    end

    test "returns {:ok, watch_ref} for a live resourceVersion", %{conn: conn} do
      FakeKubeClient.compact_before(conn, 1)
      assert {:ok, _ref} = FakeKubeClient.watch(conn, @gvk, @namespace, "5", fn _ -> :ok end)
    end

    test "ages out old revisions from ordinary writes alone, with no explicit compact call", %{
      conn: conn
    } do
      for n <- 1..4 do
        object = %{"metadata" => %{"name" => "auto-#{n}"}, "spec" => %{}}
        assert {:ok, _} = FakeKubeClient.create(conn, @gvk, @namespace, object)
      end

      # rv 1 was superseded by three later writes and is no longer retained.
      assert {:error, :gone} = FakeKubeClient.watch(conn, @gvk, @namespace, "1", fn _ -> :ok end)
      # the current resourceVersion is always live.
      assert {:ok, _ref} = FakeKubeClient.watch(conn, @gvk, @namespace, "4", fn _ -> :ok end)
    end
  end

  describe "delete/4" do
    test "removes the object so a subsequent get is :not_found", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-6"}, "spec" => %{}}
      {:ok, _created} = FakeKubeClient.create(conn, @gvk, @namespace, object)

      assert :ok = FakeKubeClient.delete(conn, @gvk, @namespace, "run-6")
      assert {:error, :not_found} = FakeKubeClient.get(conn, @gvk, @namespace, "run-6")
    end
  end

  test "FakeKubeClient is substitutable for any consumer of the port (LSP): it adopts the full behaviour" do
    assert CrestCiContract.KubeClient in FakeKubeClient.module_info(:attributes)[:behaviour]
  end
end
