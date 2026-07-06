defmodule CrestCiGateway.LogIngestTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LocalFsBlobStore
  alias CrestCiGateway.LogIngest

  setup do
    root = Path.join(System.tmp_dir!(), "log_ingest_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    store = LocalFsBlobStore.new(root)
    {:ok, deps: %LogIngest.Deps{blob_store: store, run: "run-1"}}
  end

  test "ingest_chunk appends a well-shaped chunk to the job's log", %{deps: deps} do
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "hello ")
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 1, "world")

    assert {:ok, "hello world"} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "ingest_chunk assembles chunks in strict seq order regardless of upload arrival order", %{
    deps: deps
  } do
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 2, "world")
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "hello ")
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 1, "brave ")

    assert {:ok, "hello brave world"} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "ingest_chunk is idempotent by (job, step, seq): resending an already-ingested chunk changes nothing",
       %{deps: deps} do
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "hello ")
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 1, "world")

    {:ok, before_resend} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")

    # Resend chunk 0 with *different* content, as a retried upload after a
    # gateway replica failover might: the original write wins, nothing is
    # appended, the assembled log is byte-for-byte unchanged.
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "goodbye ")

    assert {:ok, ^before_resend} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
    assert before_resend == "hello world"

    # Resending several more times must never change the outcome either.
    for _ <- 1..5 do
      assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "hello ")
    end

    assert {:ok, "hello world"} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "ingest_chunk rejects a malformed chunk without touching the store", %{deps: deps} do
    assert {:error, :invalid_log_chunk} = LogIngest.ingest_chunk(deps, "", "build", 0, "x")
    assert {:error, :invalid_log_chunk} = LogIngest.ingest_chunk(deps, "job-1", "", 0, "x")
    assert {:error, :invalid_log_chunk} = LogIngest.ingest_chunk(deps, "job-1", "build", -1, "x")
    assert {:error, :invalid_log_chunk} = LogIngest.ingest_chunk(deps, "job-1", "build", 0, nil)

    assert {:ok, ""} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "ingest_chunk accepts an empty content chunk", %{deps: deps} do
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "")
    assert {:ok, ""} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "concurrent ingestion of the same chunk key never duplicates content", %{deps: deps} do
    tasks =
      for _ <- 1..10 do
        Task.async(fn -> LogIngest.ingest_chunk(deps, "job-1", "build", 0, "hello") end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &(&1 == :ok))
    assert {:ok, "hello"} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
  end

  test "different jobs under the same run are ingested independently", %{deps: deps} do
    assert :ok = LogIngest.ingest_chunk(deps, "job-1", "build", 0, "job1 content")
    assert :ok = LogIngest.ingest_chunk(deps, "job-2", "build", 0, "job2 content")

    assert {:ok, "job1 content"} = BlobStore.read_log(deps.blob_store, "run-1", "job-1")
    assert {:ok, "job2 content"} = BlobStore.read_log(deps.blob_store, "run-1", "job-2")
  end
end
