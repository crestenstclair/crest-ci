defmodule CrestCiGateway.Results.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ArtifactRecord
  alias CrestCiGateway.Results.ArtifactStore

  # A minimal in-memory fake implementing `port.Results.ArtifactStore`,
  # used only to prove the port module dispatches every callback to
  # whichever module the opaque `store` struct belongs to, and that the
  # tagged-tuple / idempotency / atomic-finalize shapes described in the
  # port's contract survive that dispatch untouched. The real adapter
  # (`LocalFsArtifactStore`) is a separate resource; this fixture never
  # becomes production code.
  defmodule FakeArtifactStore do
    @behaviour CrestCiGateway.Results.ArtifactStore

    defstruct [:agent]

    def new do
      {:ok, agent} =
        Agent.start_link(fn -> %{uploads: %{}, parts: %{}, finalized: %{}} end)

      %__MODULE__{agent: agent}
    end

    @impl CrestCiGateway.Results.ArtifactStore
    def create(%__MODULE__{agent: agent}, run, job, name, declared_size) do
      Agent.get_and_update(agent, fn state ->
        key = {run, name}

        if Map.has_key?(state.finalized, key) or upload_exists?(state, key) do
          {{:error, :already_exists}, state}
        else
          upload_ref = make_ref()

          upload = %{
            run: run,
            job: job,
            name: name,
            declared_size: declared_size,
            key: key
          }

          {{:ok, upload_ref}, %{state | uploads: Map.put(state.uploads, upload_ref, upload)}}
        end
      end)
    end

    @impl CrestCiGateway.Results.ArtifactStore
    def upload_part(%__MODULE__{agent: agent}, upload_ref, part_index, content) do
      Agent.update(agent, fn state ->
        part_key = {upload_ref, part_index}
        # write-if-absent: idempotent by (upload_ref, part_index)
        parts = Map.put_new(state.parts, part_key, content)
        %{state | parts: parts}
      end)

      :ok
    end

    @impl CrestCiGateway.Results.ArtifactStore
    def finalize(%__MODULE__{agent: agent}, upload_ref, declared_digest) do
      Agent.get_and_update(agent, fn state ->
        case Map.fetch(state.uploads, upload_ref) do
          {:ok, upload} ->
            assembled = assemble(state.parts, upload_ref)

            with :ok <- check_size(assembled, upload.declared_size),
                 :ok <- check_digest(assembled, declared_digest) do
              {:ok, record} =
                ArtifactRecord.new(
                  declared_digest,
                  "2024-01-01T00:00:00Z",
                  upload.job,
                  upload.name,
                  upload.run,
                  byte_size(assembled)
                )

              {{:ok, record}, %{state | finalized: Map.put(state.finalized, upload.key, record)}}
            else
              {:error, reason} -> {{:error, reason}, state}
            end

          :error ->
            {{:error, :not_found}, state}
        end
      end)
    end

    @impl CrestCiGateway.Results.ArtifactStore
    def list(%__MODULE__{agent: agent}, run) do
      Agent.get(agent, fn state ->
        records =
          state.finalized
          |> Enum.filter(fn {{r, _name}, _record} -> r == run end)
          |> Enum.map(fn {_key, record} -> record end)

        {:ok, records}
      end)
    end

    @impl CrestCiGateway.Results.ArtifactStore
    def read(%__MODULE__{agent: agent}, run, name) do
      Agent.get(agent, fn state ->
        case Map.fetch(state.finalized, {run, name}) do
          {:ok, _record} ->
            upload_ref =
              state.uploads
              |> Enum.find(fn {_ref, upload} -> upload.key == {run, name} end)
              |> elem(0)

            {:ok, assemble(state.parts, upload_ref)}

          :error ->
            {:error, :not_found}
        end
      end)
    end

    defp upload_exists?(state, key) do
      Enum.any?(state.uploads, fn {_ref, upload} -> upload.key == key end)
    end

    defp assemble(parts, upload_ref) do
      parts
      |> Enum.filter(fn {{ref, _index}, _content} -> ref == upload_ref end)
      |> Enum.sort_by(fn {{_ref, index}, _content} -> index end)
      |> Enum.map(fn {_key, content} -> content end)
      |> IO.iodata_to_binary()
    end

    defp check_size(assembled, declared_size) do
      if byte_size(assembled) == declared_size do
        :ok
      else
        {:error, :size_mismatch}
      end
    end

    defp check_digest(assembled, declared_digest) do
      if ArtifactRecord.digest(assembled) == declared_digest do
        :ok
      else
        {:error, :digest_mismatch}
      end
    end
  end

  setup do
    {:ok, store: FakeArtifactStore.new()}
  end

  test "create dispatches to the store's module and returns an opaque upload_ref", %{
    store: store
  } do
    assert {:ok, upload_ref} = ArtifactStore.create(store, "run-1", "build", "out.tar", 11)
    assert upload_ref != nil
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
end
