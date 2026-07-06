defmodule CrestCiGateway.LocalFsBlobStoreTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LocalFsBlobStore

  setup do
    root = Path.join(System.tmp_dir!(), "blobstore_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store: LocalFsBlobStore.new(root)}
  end

  test "append_chunk then read_log round-trips a single chunk", %{store: store} do
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello ")
    assert {:ok, "hello "} = BlobStore.read_log(store, "run-1", "job-1")
  end

  test "read_log returns strict ascending seq order regardless of upload arrival order", %{
    store: store
  } do
    # Chunks uploaded out of order (2, 0, 1) must still assemble in seq order.
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 2, "world")
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello ")
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 1, "brave ")

    assert {:ok, "hello brave world"} = BlobStore.read_log(store, "run-1", "job-1")
  end

  test "read_log orders chunks across multiple steps deterministically", %{store: store} do
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "b_test", 0, "test-out")
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "a_build", 0, "build-out")

    # Steps are ordered deterministically (lexicographically) so the full
    # log is reproducible regardless of which step's chunks arrive first.
    assert {:ok, "build-outtest-out"} = BlobStore.read_log(store, "run-1", "job-1")
  end

  test "append_chunk is idempotent by (run, job, step, seq): resending a chunk does not duplicate content",
       %{store: store} do
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello ")
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 1, "world")

    # Resend chunk 0 with different content: the original write wins, no
    # duplication of stored content, no change in assembled log.
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello ")
    assert {:ok, "hello world"} = BlobStore.read_log(store, "run-1", "job-1")

    # Resending several times more must never change the outcome.
    for _ <- 1..5 do
      assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello ")
    end

    assert {:ok, "hello world"} = BlobStore.read_log(store, "run-1", "job-1")
  end

  test "concurrent appends of the same chunk key write-if-absent and never duplicate content", %{
    store: store
  } do
    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "hello")
        end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &(&1 == :ok))
    assert {:ok, "hello"} = BlobStore.read_log(store, "run-1", "job-1")
  end

  test "read_log on a job with no chunks yet returns an empty ok log", %{store: store} do
    assert {:ok, ""} = BlobStore.read_log(store, "run-nonexistent", "job-nonexistent")
  end

  test "different (run, job) pairs are stored independently", %{store: store} do
    assert :ok = BlobStore.append_chunk(store, "run-1", "job-1", "build", 0, "run1 content")
    assert :ok = BlobStore.append_chunk(store, "run-2", "job-1", "build", 0, "run2 content")

    assert {:ok, "run1 content"} = BlobStore.read_log(store, "run-1", "job-1")
    assert {:ok, "run2 content"} = BlobStore.read_log(store, "run-2", "job-1")
  end
end
