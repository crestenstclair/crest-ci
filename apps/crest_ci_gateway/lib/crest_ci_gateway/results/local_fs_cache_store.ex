defmodule CrestCiGateway.Results.LocalFsCacheStore do
  @moduledoc """
  Adapter: `adapter.LocalFsCacheStore` — filesystem implementation of
  `port.Results.CacheStore`.

  Layout, all under `<root>/cache/`:

    * `reservations/<res_id>/<offset>.chunk` — one file per `upload/4`
      call, opened with `:write, :exclusive`. A resend of an already-
      written `(reservation, offset)` pair hits `:eexist` and is treated
      as a no-op, so **the first write at a given offset always wins** —
      idempotency here is structural (a filesystem existence check), the
      same technique `CrestCiGateway.LocalFsBlobStore` uses for its
      `(run, job, step, seq)` chunks.
    * `blobs/<res_id>.blob` — the assembled, immutable bytes of a
      Committed entry, written once by `commit/3`.
    * `index.json` — every entry's metadata (`CacheEntry.to_wire/1` shape),
      reloadable after a restart: this module holds no process state, so
      after a crash the next call simply reads `index.json` again and
      picks up exactly where the previous process left off.

  `res_id` is a SHA-256 digest of `(scope_digest, key, version)` — fully
  deterministic, so re-deriving a reservation's paths never requires
  remembering anything beyond the opaque `Reservation` token itself.
  `scope_digest` is `CacheScope.digest/1`: `CacheEntry.scope` is
  documented as a plain string, and the digest is the canonical
  collision-resistant string form of a `CacheScope` struct.

  `lookup/4` never picks its own match and `evict/2` never picks its own
  eviction order — both delegate to the pure domain services named in
  the port's contract (`CrestCiGateway.Results.RestoreKeyResolver` and
  `CrestCiGateway.Results.LruEvictor`); this module's job is purely I/O:
  assemble bytes, touch `last_used_at` on hits, persist the index.

  Known, deliberate simplification for this slice: concurrent `reserve/4`
  calls for the same not-yet-committed `(scope, key)` are last-reservation-
  wins (the port explicitly leaves this to the adapter), and orphaned
  reservation chunk files from a reservation that is never committed are
  not garbage-collected — only Committed entries are ever eviction
  candidates, so they never affect servable state, just disk usage.
  """

  @behaviour CrestCiGateway.Results.CacheStore

  alias CrestCiGateway.Results.CacheEntry
  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.Results.LruEvictor
  alias CrestCiGateway.Results.RestoreKeyResolver

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  defmodule Reservation do
    @moduledoc """
    Opaque reservation token for `LocalFsCacheStore`: everything needed to
    re-derive this reservation's on-disk paths, and nothing else. Callers
    of `port.Results.CacheStore` never inspect this struct — they hold it
    and pass it back into `upload/4` and `commit/3` verbatim.
    """

    @enforce_keys [:key, :scope_digest, :version]
    defstruct [:key, :scope_digest, :version]

    @type t :: %__MODULE__{
            key: String.t(),
            scope_digest: String.t(),
            version: String.t()
          }
  end

  @doc """
  Builds a store rooted at `root`, ensuring `<root>/cache/` exists.
  """
  @spec new(String.t()) :: t()
  def new(root) when is_binary(root) and byte_size(root) > 0 do
    root |> cache_dir() |> File.mkdir_p!()
    %__MODULE__{root: root}
  end

  @impl CrestCiGateway.Results.CacheStore
  @spec reserve(t(), String.t(), String.t(), CacheScope.t()) ::
          {:ok, Reservation.t()} | {:error, :already_committed}
  def reserve(%__MODULE__{} = store, key, version, %CacheScope{} = scope)
      when is_binary(key) and byte_size(key) > 0 and
             is_binary(version) and byte_size(version) > 0 do
    scope_digest = CacheScope.digest(scope)
    entries = load_index(store)

    case find_entry(entries, scope_digest, key) do
      %CacheEntry{state: :committed} ->
        {:error, :already_committed}

      _not_committed ->
        {:ok, %Reservation{key: key, scope_digest: scope_digest, version: version}}
    end
  end

  @impl CrestCiGateway.Results.CacheStore
  @spec upload(t(), Reservation.t(), non_neg_integer(), binary()) :: :ok
  def upload(%__MODULE__{root: root}, %Reservation{} = reservation, offset, content)
      when is_integer(offset) and offset >= 0 and is_binary(content) do
    res_id = res_id(reservation)
    path = chunk_path(root, res_id, offset)
    File.mkdir_p!(Path.dirname(path))
    write_chunk_if_absent(path, content)
    :ok
  end

  @impl CrestCiGateway.Results.CacheStore
  @spec commit(t(), Reservation.t(), non_neg_integer()) ::
          {:ok, CacheEntry.t()} | {:error, :size_mismatch}
  def commit(%__MODULE__{root: root} = store, %Reservation{} = reservation, declared_size)
      when is_integer(declared_size) and declared_size >= 0 do
    res_id = res_id(reservation)
    assembled = assemble_chunks(root, res_id)

    if byte_size(assembled) == declared_size do
      blob = blob_path(root, res_id)
      File.mkdir_p!(Path.dirname(blob))
      File.write!(blob, assembled)

      now = timestamp()

      {:ok, entry} =
        CacheEntry.new(
          reservation.key,
          reservation.scope_digest,
          declared_size,
          :committed,
          reservation.version,
          now,
          now
        )

      store |> load_index() |> upsert_entry(entry) |> then(&save_index(store, &1))
      {:ok, entry}
    else
      {:error, :size_mismatch}
    end
  end

  @impl CrestCiGateway.Results.CacheStore
  @spec lookup(t(), String.t(), [String.t()], [CacheScope.t()]) ::
          {:ok, CacheEntry.t(), binary()} | :miss
  def lookup(%__MODULE__{root: root} = store, key, restore_keys, scope_chain)
      when is_binary(key) and is_list(restore_keys) and is_list(scope_chain) do
    entries = load_index(store)

    case RestoreKeyResolver.resolve(key, restore_keys, scope_chain, entries) do
      {:ok, %CacheEntry{} = winner} ->
        res_id = res_id_from_entry(winner)
        content = File.read!(blob_path(root, res_id))
        touched = CacheEntry.touch(winner, timestamp())
        entries |> upsert_entry(touched) |> then(&save_index(store, &1))
        {:ok, touched, content}

      :miss ->
        :miss
    end
  end

  @impl CrestCiGateway.Results.CacheStore
  @spec evict(t(), non_neg_integer()) :: {:ok, [CacheEntry.t()]}
  def evict(%__MODULE__{root: root} = store, byte_budget)
      when is_integer(byte_budget) and byte_budget >= 0 do
    entries = load_index(store)
    evicted = LruEvictor.evict(entries, byte_budget)
    evicted_identities = MapSet.new(evicted, &CacheEntry.identity/1)

    remaining =
      Enum.reject(entries, fn e -> MapSet.member?(evicted_identities, CacheEntry.identity(e)) end)

    Enum.each(evicted, fn e ->
      res_id = res_id_from_entry(e)
      File.rm(blob_path(root, res_id))
      File.rm_rf(reservation_dir(root, res_id))
    end)

    save_index(store, remaining)
    {:ok, evicted}
  end

  # -- internal --------------------------------------------------------

  defp cache_dir(root), do: Path.join(root, "cache")
  defp index_path(root), do: Path.join(cache_dir(root), "index.json")
  defp reservation_dir(root, res_id), do: Path.join([cache_dir(root), "reservations", res_id])

  defp chunk_path(root, res_id, offset),
    do: Path.join(reservation_dir(root, res_id), "#{offset}.chunk")

  defp blob_path(root, res_id), do: Path.join([cache_dir(root), "blobs", res_id <> ".blob"])

  defp res_id(%Reservation{scope_digest: scope_digest, key: key, version: version}) do
    res_id(scope_digest, key, version)
  end

  defp res_id_from_entry(%CacheEntry{scope: scope_digest, key: key, version: version}) do
    res_id(scope_digest, key, version)
  end

  defp res_id(scope_digest, key, version) do
    :crypto.hash(:sha256, [scope_digest, <<0>>, key, <<0>>, version])
    |> Base.encode16(case: :lower)
  end

  defp write_chunk_if_absent(path, content) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, content)
        after
          File.close(io)
        end

      {:error, :eexist} ->
        # First write at this (reservation, offset) already won — a
        # resend, even with different bytes, changes nothing.
        :ok

      {:error, reason} ->
        raise "failed writing cache chunk #{path}: #{inspect(reason)}"
    end
  end

  defp assemble_chunks(root, res_id) do
    dir = reservation_dir(root, res_id)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(&parse_offset/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.map(fn offset -> File.read!(chunk_path(root, res_id, offset)) end)
        |> IO.iodata_to_binary()

      {:error, :enoent} ->
        ""
    end
  end

  @offset_pattern ~r/^(\d+)\.chunk$/

  defp parse_offset(filename) do
    case Regex.run(@offset_pattern, filename) do
      [_, offset_str] -> String.to_integer(offset_str)
      _other -> nil
    end
  end

  defp load_index(%__MODULE__{root: root}) do
    case File.read(index_path(root)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"entries" => wire_entries}} ->
            Enum.flat_map(wire_entries, fn wire ->
              case CacheEntry.from_wire(wire) do
                {:ok, entry} -> [entry]
                {:error, _reason} -> []
              end
            end)

          _other ->
            []
        end

      {:error, :enoent} ->
        []
    end
  end

  defp save_index(%__MODULE__{root: root}, entries) do
    path = index_path(root)
    File.mkdir_p!(Path.dirname(path))
    tmp_path = path <> ".tmp-#{System.unique_integer([:positive])}"
    wire = %{"entries" => Enum.map(entries, &CacheEntry.to_wire/1)}
    File.write!(tmp_path, Jason.encode!(wire))
    File.rename!(tmp_path, path)
    :ok
  end

  defp find_entry(entries, scope_digest, key) do
    Enum.find(entries, fn e -> e.scope == scope_digest and e.key == key end)
  end

  defp upsert_entry(entries, %CacheEntry{} = entry) do
    identity = CacheEntry.identity(entry)
    filtered = Enum.reject(entries, fn e -> CacheEntry.identity(e) == identity end)
    [entry | filtered]
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
