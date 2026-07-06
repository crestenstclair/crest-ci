defmodule CrestCiContract.ReqKubeClientTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.ReqKubeClient
  alias CrestCiContract.Test.FakeKubeHttpServer

  @gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @core_gvk {"core", "v1", "Pod"}
  @namespace "default"

  setup do
    {:ok, store} = FakeKubeHttpServer.start_link()
    {:ok, bandit, port} = FakeKubeHttpServer.serve(store)
    on_exit(fn -> if Process.alive?(bandit), do: Process.exit(bandit, :shutdown) end)

    conn = ReqKubeClient.new("http://127.0.0.1:#{port}", retry: false)
    %{conn: conn, store: store}
  end

  describe "get/4" do
    test "returns {:error, :not_found} for an absent name", %{conn: conn} do
      assert {:error, :not_found} = ReqKubeClient.get(conn, @gvk, @namespace, "missing")
    end

    test "returns {:ok, object} once created", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-1"}, "spec" => %{}}
      assert {:ok, created} = ReqKubeClient.create(conn, @gvk, @namespace, object)
      assert {:ok, fetched} = ReqKubeClient.get(conn, @gvk, @namespace, "run-1")
      assert fetched == created
    end

    test "speaks the core-group URL shape for core-group gvks", %{conn: conn} do
      object = %{"metadata" => %{"name" => "web"}, "spec" => %{}}
      assert {:ok, _created} = ReqKubeClient.create(conn, @core_gvk, @namespace, object)
      assert {:ok, fetched} = ReqKubeClient.get(conn, @core_gvk, @namespace, "web")
      assert fetched["metadata"]["name"] == "web"
    end
  end

  describe "create/4" do
    test "returns {:error, :already_exists} on a deterministic-name collision", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-1-j-build"}, "spec" => %{}}
      assert {:ok, _} = ReqKubeClient.create(conn, @gvk, @namespace, object)
      assert {:error, :already_exists} = ReqKubeClient.create(conn, @gvk, @namespace, object)
    end
  end

  describe "list/4" do
    test "returns every created object in the namespace", %{conn: conn} do
      {:ok, _} = ReqKubeClient.create(conn, @gvk, @namespace, %{"metadata" => %{"name" => "a"}})
      {:ok, _} = ReqKubeClient.create(conn, @gvk, @namespace, %{"metadata" => %{"name" => "b"}})

      assert {:ok, items, nil} = ReqKubeClient.list(conn, @gvk, @namespace, [])
      names = items |> Enum.map(& &1["metadata"]["name"]) |> Enum.sort()
      assert names == ["a", "b"]
    end
  end

  describe "update/4" do
    test "returns {:error, :conflict} on a stale resourceVersion and never forces the write", %{
      conn: conn
    } do
      object = %{"metadata" => %{"name" => "run-2"}, "spec" => %{"a" => 1}}
      {:ok, created} = ReqKubeClient.create(conn, @gvk, @namespace, object)

      stale = put_in(created, ["spec", "a"], 2)
      {:ok, _current} = ReqKubeClient.update(conn, @gvk, @namespace, created)

      assert {:error, :conflict} = ReqKubeClient.update(conn, @gvk, @namespace, stale)

      {:ok, after_conflict} = ReqKubeClient.get(conn, @gvk, @namespace, "run-2")
      refute after_conflict["spec"]["a"] == 2
    end

    test "succeeds against the current resourceVersion", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-3"}, "spec" => %{"a" => 1}}
      {:ok, created} = ReqKubeClient.create(conn, @gvk, @namespace, object)

      updated = put_in(created, ["spec", "a"], 2)
      assert {:ok, result} = ReqKubeClient.update(conn, @gvk, @namespace, updated)
      assert result["spec"]["a"] == 2
    end
  end

  describe "patch_status/6" do
    test "returns {:error, :conflict} on a stale expected_resource_version and never forces the write",
         %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-4"}, "spec" => %{}}
      {:ok, created} = ReqKubeClient.create(conn, @gvk, @namespace, object)
      stale_rv = created["metadata"]["resourceVersion"]

      # Someone else updates first, advancing the resourceVersion.
      {:ok, _current} = ReqKubeClient.update(conn, @gvk, @namespace, created)

      assert {:error, :conflict} =
               ReqKubeClient.patch_status(
                 conn,
                 @gvk,
                 @namespace,
                 "run-4",
                 %{"phase" => "Bad"},
                 stale_rv
               )

      {:ok, after_conflict} = ReqKubeClient.get(conn, @gvk, @namespace, "run-4")
      refute after_conflict["status"]["phase"] == "Bad"
    end

    test "succeeds against the current resourceVersion", %{conn: conn} do
      object = %{"metadata" => %{"name" => "run-5"}, "spec" => %{}}
      {:ok, created} = ReqKubeClient.create(conn, @gvk, @namespace, object)
      rv = created["metadata"]["resourceVersion"]

      assert {:ok, result} =
               ReqKubeClient.patch_status(
                 conn,
                 @gvk,
                 @namespace,
                 "run-5",
                 %{"phase" => "Running"},
                 rv
               )

      assert result["status"]["phase"] == "Running"
    end
  end

  describe "delete/4" do
    test "removes the object; subsequent get returns :not_found", %{conn: conn} do
      {:ok, _} =
        ReqKubeClient.create(conn, @gvk, @namespace, %{"metadata" => %{"name" => "run-6"}})

      assert :ok = ReqKubeClient.delete(conn, @gvk, @namespace, "run-6")
      assert {:error, :not_found} = ReqKubeClient.get(conn, @gvk, @namespace, "run-6")
    end

    test "returns {:error, :not_found} for an absent name", %{conn: conn} do
      assert {:error, :not_found} = ReqKubeClient.delete(conn, @gvk, @namespace, "nope")
    end
  end

  describe "watch/5" do
    test "delivers created and updated objects live, in order", %{conn: conn} do
      test_pid = self()

      assert {:ok, watch_ref} =
               ReqKubeClient.watch(conn, @gvk, @namespace, "", fn event ->
                 send(test_pid, {:watch_event, event})
               end)

      {:ok, created} =
        ReqKubeClient.create(conn, @gvk, @namespace, %{"metadata" => %{"name" => "run-7"}})

      {:ok, _updated} =
        ReqKubeClient.update(conn, @gvk, @namespace, put_in(created, ["spec"], %{"a" => 1}))

      assert_receive {:watch_event, {:added, added_object}}, 2_000
      assert added_object["metadata"]["name"] == "run-7"

      assert_receive {:watch_event, {:modified, modified_object}}, 2_000
      assert modified_object["spec"]["a"] == 1

      ReqKubeClient.cancel_watch(watch_ref)
    end

    test "returns {:error, :gone} when the store reports a compacted-away resourceVersion", %{
      conn: conn,
      store: store
    } do
      FakeKubeHttpServer.force_gone(store)

      assert {:error, :gone} =
               ReqKubeClient.watch(conn, @gvk, @namespace, "1", fn _event -> :ok end)
    end
  end
end
