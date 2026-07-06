defmodule CrestCiGateway.Results.CacheStoreTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.Results.CacheStore

  # A minimal in-memory fake implementing `port.Results.CacheStore`, used
  # only to prove the port module dispatches every callback to whichever
  # module the opaque `store` struct belongs to, and that the tagged-tuple
  # / idempotency shapes described in the port's contract survive that
  # dispatch untouched. The real adapter (`LocalFsCacheStore`) is a
  # separate resource; this fixture never becomes production code.
  defmodule FakeCacheStore do
    @behaviour CrestCiGateway.Results.CacheStore

    defstruct [:agent]

    def new do
      {:ok, agent} = Agent.start_link(fn -> %{committed: %{}, reserved: %{}, blobs: %{}} end)
      %__MODULE__{agent: agent}
    end

    @impl CrestCiGateway.Results.CacheStore
    def reserve(%__MODULE__{agent: agent}, key, version, scope) do
      Agent.get_and_update(agent, fn state ->
        if Map.has_key?(state.committed, key) do
          {{:error, :already_committed}, state}
        else
          reservation = {key, version, scope, make_ref()}
          {{:ok, reservation}, state}
        end
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def upload(%__MODULE__{agent: agent}, reservation, offset, content) do
      Agent.update(agent, fn state ->
        blob_key = {reservation, offset}
        # write-if-absent: idempotent by (reservation, offset)
        blobs = Map.put_new(state.blobs, blob_key, content)
        %{state | blobs: blobs}
      end)

      :ok
    end

    @impl CrestCiGateway.Results.CacheStore
    def commit(
          %__MODULE__{agent: agent},
          {key, _version, _scope, _tag} = reservation,
          declared_size
        ) do
      Agent.get_and_update(agent, fn state ->
        assembled =
          state.blobs
          |> Enum.filter(fn {{r, _offset}, _content} -> r == reservation end)
          |> Enum.sort_by(fn {{_r, offset}, _content} -> offset end)
          |> Enum.map(fn {_k, content} -> content end)
          |> IO.iodata_to_binary()

        if byte_size(assembled) == declared_size do
          entry = %{key: key, size: declared_size, content: assembled}
          {{:ok, entry}, %{state | committed: Map.put(state.committed, key, entry)}}
        else
          {{:error, :size_mismatch}, state}
        end
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def lookup(%__MODULE__{agent: agent}, key, _restore_keys, _scope_chain) do
      Agent.get(agent, fn state ->
        case Map.fetch(state.committed, key) do
          {:ok, entry} -> {:ok, entry, entry.content}
          :error -> :miss
        end
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def evict(%__MODULE__{agent: agent}, byte_budget) do
      Agent.get(agent, fn state ->
        total = state.committed |> Map.values() |> Enum.map(& &1.size) |> Enum.sum()

        if total <= byte_budget do
          {:ok, []}
        else
          {:ok, Map.values(state.committed)}
        end
      end)
    end
  end

  setup do
    {:ok, scope} = CacheScope.new("refs/heads/main", "acme/widgets")
    {:ok, store: FakeCacheStore.new(), scope: scope}
  end

  test "reserve dispatches to the store's module and returns an opaque reservation", %{
    store: store,
    scope: scope
  } do
    assert {:ok, reservation} = CacheStore.reserve(store, "deps-otp27-a1b2c3", "v1", scope)
    assert reservation != nil
  end

  test "reserve rejects a key that already names a Committed entry", %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-otp27-a1b2c3", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "hello")
    {:ok, _entry} = CacheStore.commit(store, reservation, 5)

    assert {:error, :already_committed} =
             CacheStore.reserve(store, "deps-otp27-a1b2c3", "v2", scope)
  end

  test "upload is idempotent by (reservation, offset): resending an offset does not corrupt the blob",
       %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-idempotent", "v1", scope)

    assert :ok = CacheStore.upload(store, reservation, 0, "hello ")
    assert :ok = CacheStore.upload(store, reservation, 6, "world")
    # Resend offset 0 with different content: the first write wins.
    assert :ok = CacheStore.upload(store, reservation, 0, "HELLO")

    assert {:ok, entry} = CacheStore.commit(store, reservation, 11)
    assert entry.content == "hello world"
  end

  test "commit rejects a size mismatch and leaves nothing servable under that key", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-bad-size", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "hello")

    assert {:error, :size_mismatch} = CacheStore.commit(store, reservation, 999)
    assert :miss = CacheStore.lookup(store, "deps-bad-size", [], [scope])
  end

  test "lookup on a committed key returns the entry and its bytes", %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-hit", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "cached-bytes")
    {:ok, _entry} = CacheStore.commit(store, reservation, byte_size("cached-bytes"))

    assert {:ok, entry, "cached-bytes"} = CacheStore.lookup(store, "deps-hit", [], [scope])
    assert entry.key == "deps-hit"
  end

  test "lookup on an unknown key is a soft miss, never an error", %{store: store, scope: scope} do
    assert :miss = CacheStore.lookup(store, "never-committed", ["deps-"], [scope])
  end

  test "evict returns an empty list when total size is within budget", %{
    store: store,
    scope: scope
  } do
    {:ok, reservation} = CacheStore.reserve(store, "deps-small", "v1", scope)
    :ok = CacheStore.upload(store, reservation, 0, "tiny")
    {:ok, _entry} = CacheStore.commit(store, reservation, 4)

    assert {:ok, []} = CacheStore.evict(store, 1_000_000)
  end

  test "evict returns candidates once total size exceeds budget", %{store: store, scope: scope} do
    {:ok, reservation} = CacheStore.reserve(store, "deps-big", "v1", scope)
    content = String.duplicate("x", 100)
    :ok = CacheStore.upload(store, reservation, 0, content)
    {:ok, _entry} = CacheStore.commit(store, reservation, 100)

    assert {:ok, [evicted]} = CacheStore.evict(store, 10)
    assert evicted.key == "deps-big"
  end
end
