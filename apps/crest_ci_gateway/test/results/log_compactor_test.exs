defmodule CrestCiGateway.Results.LogCompactorTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LocalFsBlobStore
  alias CrestCiGateway.LogArchive
  alias CrestCiGateway.LogChunk
  alias CrestCiGateway.Results.LogCompactor

  setup do
    root =
      Path.join(System.tmp_dir!(), "log_compactor_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    store = LocalFsBlobStore.new(root)
    {:ok, deps: %LogCompactor.Deps{blob_store: store, run: "run-1"}}
  end

  defp chunk!(job_key, step, seq, content) do
    {:ok, chunk} = LogChunk.new(job_key, step, seq, content)
    chunk
  end

  describe "plan/2" do
    test "orders chunks by step then by seq within step, regardless of input order" do
      chunks = [
        chunk!("job-1", "test", 1, "-test1"),
        chunk!("job-1", "build", 1, "-build1"),
        chunk!("job-1", "test", 0, "test0"),
        chunk!("job-1", "build", 0, "build0")
      ]

      {ordered, content} = LogCompactor.plan("job-1", chunks)

      assert Enum.map(ordered, &{&1.step, &1.seq}) == [
               {"build", 0},
               {"build", 1},
               {"test", 0},
               {"test", 1}
             ]

      assert content == "build0-build1test0-test1"
    end

    test "deduplicates by (step, seq), first occurrence wins" do
      chunks = [
        chunk!("job-1", "build", 0, "first"),
        chunk!("job-1", "build", 0, "resent-different-content")
      ]

      {ordered, content} = LogCompactor.plan("job-1", chunks)

      assert [%LogChunk{content: "first"}] = ordered
      assert content == "first"
    end

    test "filters out chunks belonging to a different job_key" do
      chunks = [
        chunk!("job-1", "build", 0, "mine"),
        chunk!("job-2", "build", 0, "not mine")
      ]

      {ordered, content} = LogCompactor.plan("job-1", chunks)

      assert [%LogChunk{job_key: "job-1"}] = ordered
      assert content == "mine"
    end

    test "returns an empty plan for no chunks" do
      assert {[], ""} = LogCompactor.plan("job-1", [])
    end
  end

  describe "compact/4 — first compaction (no existing archive)" do
    test "writes the compacted content durably and returns archive metadata + deletion list", %{
      deps: deps
    } do
      chunks = [
        chunk!("job-1", "build", 0, "line1\n"),
        chunk!("job-1", "build", 1, "line2\n")
      ]

      assert {:ok, %LogArchive{} = archive, deletion_list} =
               LogCompactor.compact(deps, "job-1", nil, chunks)

      assert archive.job_key == "job-1"
      assert archive.run_ref == LogCompactor.archive_ref("job-1")
      assert archive.byte_size == byte_size("line1\nline2\n")
      assert archive.line_count == 2

      assert Enum.map(deletion_list, &{&1.step, &1.seq}) == [{"build", 0}, {"build", 1}]

      assert {:ok, "line1\nline2\n"} =
               BlobStore.read_log(deps.blob_store, deps.run, LogCompactor.archive_ref("job-1"))
    end

    test "never disturbs the job's own live-chunk directory", %{deps: deps} do
      # The live chunk must actually be ingested into the blob store first
      # (as `LogIngest` would do in production) — compaction only reads
      # the in-memory `chunks` list to build the archive, it never writes
      # to the job's own live-chunk directory, so asserting that
      # directory is undisturbed requires something to have been written
      # there before `compact/4` runs.
      :ok = BlobStore.append_chunk(deps.blob_store, deps.run, "job-1", "build", 0, "hello")
      chunks = [chunk!("job-1", "build", 0, "hello")]

      assert {:ok, _archive, _deletion_list} = LogCompactor.compact(deps, "job-1", nil, chunks)

      assert {:ok, "hello"} = BlobStore.read_log(deps.blob_store, deps.run, "job-1")
    end

    test "produces an empty (valid) archive when there are no chunks yet", %{deps: deps} do
      assert {:ok, %LogArchive{byte_size: 0, line_count: 0}, []} =
               LogCompactor.compact(deps, "job-1", nil, [])
    end

    test "is idempotent: compacting the same job twice writes identical bytes", %{deps: deps} do
      chunks = [
        chunk!("job-1", "build", 0, "hello "),
        chunk!("job-1", "build", 1, "world")
      ]

      assert {:ok, archive_1, deletion_1} = LogCompactor.compact(deps, "job-1", nil, chunks)
      assert {:ok, archive_2, deletion_2} = LogCompactor.compact(deps, "job-1", nil, chunks)

      assert archive_1 == archive_2
      assert deletion_1 == deletion_2

      assert {:ok, "hello world"} =
               BlobStore.read_log(deps.blob_store, deps.run, LogCompactor.archive_ref("job-1"))
    end

    test "dedupes duplicate resends before archiving (first write wins)", %{deps: deps} do
      chunks = [
        chunk!("job-1", "build", 0, "hello "),
        chunk!("job-1", "build", 1, "world"),
        chunk!("job-1", "build", 0, "goodbye ")
      ]

      assert {:ok, archive, deletion_list} = LogCompactor.compact(deps, "job-1", nil, chunks)

      assert archive.byte_size == byte_size("hello world")
      assert length(deletion_list) == 2

      assert {:ok, "hello world"} =
               BlobStore.read_log(deps.blob_store, deps.run, LogCompactor.archive_ref("job-1"))
    end

    test "rejects a malformed job_key without touching the store", %{deps: deps} do
      assert {:error, :invalid_job_key} = LogCompactor.compact(deps, "", nil, [])
      assert {:error, :invalid_job_key} = LogCompactor.compact(deps, nil, nil, [])
    end
  end

  describe "compact/4 — already-archived job is a no-op" do
    test "returns the existing archive unchanged with an empty deletion list, touching nothing",
         %{
           deps: deps
         } do
      {:ok, existing_archive} = LogArchive.new("job-1", "archives/job-1", 11, 1)

      chunks = [chunk!("job-1", "build", 0, "should not be written")]

      assert {:ok, ^existing_archive, []} =
               LogCompactor.compact(deps, "job-1", existing_archive, chunks)

      assert {:ok, ""} =
               BlobStore.read_log(deps.blob_store, deps.run, LogCompactor.archive_ref("job-1"))
    end
  end

  describe "archive_ref/1" do
    test "is deterministic and distinct from the raw job_key" do
      assert LogCompactor.archive_ref("job-1") == LogCompactor.archive_ref("job-1")
      refute LogCompactor.archive_ref("job-1") == "job-1"
    end
  end
end
