defmodule CrestCiGateway.Results.LocalFsArtifactStoreTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ArtifactRecord
  alias CrestCiGateway.Results.ArtifactStore
  alias CrestCiGateway.Results.LocalFsArtifactStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "artifactstore_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store: LocalFsArtifactStore.new(root)}
  end

  test "create then upload_part then finalize round-trips a single-part artifact", %{
    store: store
  } do
    assert {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "out.tar", 11)
    assert :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello world")

    digest = ArtifactRecord.digest("hello world")
    assert {:ok, record} = ArtifactStore.finalize(store, upload_ref, digest)
    assert record.digest == digest
    assert record.name == "out.tar"
    assert record.run_ref == "run-1"
    assert record.size_bytes == 11

    assert {:ok, "hello world"} = ArtifactStore.read(store, "run-1", "out.tar")
  end

  test "finalize assembles multiple parts in ascending index order regardless of upload order",
       %{store: store} do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "multi.txt", 11)

    # Uploaded out of order (1, then 0): assembly must still be by index.
    assert :ok = ArtifactStore.upload_part(store, upload_ref, 1, "world")
    assert :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello ")

    digest = ArtifactRecord.digest("hello world")
    assert {:ok, _record} = ArtifactStore.finalize(store, upload_ref, digest)
    assert {:ok, "hello world"} = ArtifactStore.read(store, "run-1", "multi.txt")
  end

  test "create rejects a name that already has a finalized artifact under (run, name)", %{
    store: store
  } do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "dup.txt", 5)
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello")
    digest = ArtifactRecord.digest("hello")
    {:ok, _record} = ArtifactStore.finalize(store, upload_ref, digest)

    assert {:error, :already_exists} =
             ArtifactStore.create(store, "run-1", "build", "dup.txt", 5)
  end

  test "create called twice for the same (run, job, name) before finalize is a deterministic collision",
       %{store: store} do
    assert {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "in-flight.txt", 5)

    assert {:error, :already_exists} =
             ArtifactStore.create(store, "run-1", "build", "in-flight.txt", 5)

    # The original upload is unaffected by the rejected second create.
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello")
    digest = ArtifactRecord.digest("hello")
    assert {:ok, _record} = ArtifactStore.finalize(store, upload_ref, digest)
  end

  test "upload_part is idempotent by (upload_ref, part_index): resending a part does not corrupt the assembly",
       %{store: store} do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "idempotent.txt", 11)

    assert :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello ")
    assert :ok = ArtifactStore.upload_part(store, upload_ref, 1, "world")
    # Resend part 0 with different content: the first write wins.
    assert :ok = ArtifactStore.upload_part(store, upload_ref, 0, "HELLO ")

    digest = ArtifactRecord.digest("hello world")
    assert {:ok, record} = ArtifactStore.finalize(store, upload_ref, digest)
    assert record.digest == digest
    assert {:ok, "hello world"} = ArtifactStore.read(store, "run-1", "idempotent.txt")
  end

  test "finalize rejects a size mismatch and leaves nothing visible under that name", %{
    store: store
  } do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "bad-size.txt", 999)
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello")

    digest = ArtifactRecord.digest("hello")
    assert {:error, :size_mismatch} = ArtifactStore.finalize(store, upload_ref, digest)

    assert {:ok, []} = ArtifactStore.list(store, "run-1")
    assert {:error, :not_found} = ArtifactStore.read(store, "run-1", "bad-size.txt")
  end

  test "finalize rejects a digest mismatch and leaves nothing visible under that name", %{
    store: store
  } do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "bad-digest.txt", 5)
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello")

    wrong_digest = ArtifactRecord.digest("wrong-content-of-same-size")

    assert {:error, :digest_mismatch} = ArtifactStore.finalize(store, upload_ref, wrong_digest)

    assert {:ok, []} = ArtifactStore.list(store, "run-1")
    assert {:error, :not_found} = ArtifactStore.read(store, "run-1", "bad-digest.txt")
  end

  test "list returns only finalized artifacts for a run, never in-flight uploads", %{
    store: store
  } do
    {:ok, finalized_ref} = ArtifactStore.create(store, "run-2", "build", "finalized.txt", 5)
    :ok = ArtifactStore.upload_part(store, finalized_ref, 0, "hello")
    {:ok, _record} = ArtifactStore.finalize(store, finalized_ref, ArtifactRecord.digest("hello"))

    {:ok, _in_flight_ref} = ArtifactStore.create(store, "run-2", "build", "in-flight.txt", 5)

    assert {:ok, [record]} = ArtifactStore.list(store, "run-2")
    assert record.name == "finalized.txt"
  end

  test "list on a run with no finalized artifacts returns an empty ok list", %{store: store} do
    assert {:ok, []} = ArtifactStore.list(store, "run-nonexistent")
  end

  test "read returns the finalized artifact's full assembled bytes", %{store: store} do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-3", "build", "content.txt", 11)
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "hello ")
    :ok = ArtifactStore.upload_part(store, upload_ref, 1, "world")

    {:ok, _record} =
      ArtifactStore.finalize(store, upload_ref, ArtifactRecord.digest("hello world"))

    assert {:ok, "hello world"} = ArtifactStore.read(store, "run-3", "content.txt")
  end

  test "read on an artifact that was never created is :not_found, identically to one never finalized",
       %{store: store} do
    assert {:error, :not_found} = ArtifactStore.read(store, "run-4", "never-created.txt")

    {:ok, _upload_ref} = ArtifactStore.create(store, "run-4", "build", "never-finalized.txt", 5)
    assert {:error, :not_found} = ArtifactStore.read(store, "run-4", "never-finalized.txt")
  end

  test "different (run, name) pairs are stored and finalized independently", %{store: store} do
    {:ok, ref1} = ArtifactStore.create(store, "run-a", "build", "out.txt", 5)
    :ok = ArtifactStore.upload_part(store, ref1, 0, "alpha")
    {:ok, _record1} = ArtifactStore.finalize(store, ref1, ArtifactRecord.digest("alpha"))

    {:ok, ref2} = ArtifactStore.create(store, "run-b", "build", "out.txt", 4)
    :ok = ArtifactStore.upload_part(store, ref2, 0, "beta")
    {:ok, _record2} = ArtifactStore.finalize(store, ref2, ArtifactRecord.digest("beta"))

    assert {:ok, "alpha"} = ArtifactStore.read(store, "run-a", "out.txt")
    assert {:ok, "beta"} = ArtifactStore.read(store, "run-b", "out.txt")
  end

  test "an artifact name with nested path segments round-trips through create/upload/finalize/read",
       %{store: store} do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-5", "build", "dist/app.tar.gz", 7)
    :ok = ArtifactStore.upload_part(store, upload_ref, 0, "payload")

    digest = ArtifactRecord.digest("payload")
    assert {:ok, record} = ArtifactStore.finalize(store, upload_ref, digest)
    assert record.name == "dist/app.tar.gz"

    assert {:ok, "payload"} = ArtifactStore.read(store, "run-5", "dist/app.tar.gz")
    assert {:ok, [listed]} = ArtifactStore.list(store, "run-5")
    assert listed.name == "dist/app.tar.gz"
  end

  test "concurrent upload_part calls for the same (upload_ref, part_index) write-if-absent and never corrupt content",
       %{store: store} do
    {:ok, upload_ref} = ArtifactStore.create(store, "run-6", "build", "race.txt", 5)

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> ArtifactStore.upload_part(store, upload_ref, 0, "hello") end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &(&1 == :ok))

    digest = ArtifactRecord.digest("hello")
    assert {:ok, _record} = ArtifactStore.finalize(store, upload_ref, digest)
    assert {:ok, "hello"} = ArtifactStore.read(store, "run-6", "race.txt")
  end
end
