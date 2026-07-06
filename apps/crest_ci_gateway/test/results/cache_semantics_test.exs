defmodule CrestCiGateway.Results.CacheSemanticsTest do
  @moduledoc """
  Cross-component behavior suite: boots a real gateway-style HTTP endpoint
  in front of a filesystem-backed `port.Results.CacheStore` adapter and
  exercises GitHub-compatible restore-key / scope-chain semantics plus LRU
  eviction over real sockets (no `Plug.Test` conn/2 shortcuts).

  Everything the suite needs — the store adapter, the pure restore-key and
  eviction domain services it delegates to, and the thin HTTP transport —
  is defined locally to this test file, mirroring the existing convention
  in `cache_store_test.exs` / `artifact_store_test.exs` (an in-file fixture
  that never becomes production code; `LocalFsCacheStore`,
  `RestoreKeyResolver`, and `LruEvictor` proper are separate resources).
  """

  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheEntry
  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.Results.CacheStore

  # ===========================================================================
  # Pure domain service: restore-key resolution (GitHub semantics)
  # ===========================================================================

  defmodule RestoreKeyResolver do
    @moduledoc """
    Pure, I/O-free match selection for `CacheStore.lookup/4`: exact key
    first, then each `restore_keys` prefix in order, picking the most
    recently used entry among a prefix's matches. Scope filtering has
    already happened by the time entries reach this module — it never
    sees an entry outside the caller's scope chain.
    """

    @spec resolve([CacheEntry.t()], String.t(), [String.t()]) ::
            {:ok, CacheEntry.t()} | :miss
    def resolve(entries, key, restore_keys) do
      committed = Enum.filter(entries, &(&1.state == :committed))

      case Enum.find(committed, &(&1.key == key)) do
        nil -> resolve_by_prefix(committed, restore_keys)
        entry -> {:ok, entry}
      end
    end

    defp resolve_by_prefix(_entries, []), do: :miss

    defp resolve_by_prefix(entries, [prefix | rest]) do
      case Enum.filter(entries, &String.starts_with?(&1.key, prefix)) do
        [] -> resolve_by_prefix(entries, rest)
        matches -> {:ok, Enum.max_by(matches, & &1.last_used_at)}
      end
    end
  end

  # ===========================================================================
  # Pure domain service: LRU eviction
  # ===========================================================================

  defmodule LruEvictor do
    @moduledoc """
    Pure, I/O-free eviction-order selection for `CacheStore.evict/2`:
    oldest-`last_used_at`-first among the *Committed* entries handed to it,
    stopping as soon as the running total respects `byte_budget`. Callers
    are responsible for never passing Reserved entries in — this module
    has no concept of entry state beyond what it's given.
    """

    @spec evict([CacheEntry.t()], non_neg_integer()) :: {:ok, [CacheEntry.t()]}
    def evict(entries, byte_budget) do
      total = Enum.reduce(entries, 0, fn e, acc -> acc + e.size_bytes end)

      if total <= byte_budget do
        {:ok, []}
      else
        sorted = Enum.sort_by(entries, & &1.last_used_at)

        {victims, _remaining} =
          Enum.reduce_while(sorted, {[], total}, fn entry, {acc, remaining} ->
            if remaining <= byte_budget do
              {:halt, {acc, remaining}}
            else
              {:cont, {[entry | acc], remaining - entry.size_bytes}}
            end
          end)

        {:ok, Enum.reverse(victims)}
      end
    end
  end

  # ===========================================================================
  # Adapter fixture: filesystem-backed CacheStore
  # ===========================================================================

  defmodule LocalFsCacheStore do
    @moduledoc """
    Filesystem adapter implementing `port.Results.CacheStore`, in the same
    "no in-process state, everything re-derivable from disk" style as
    `CrestCiGateway.LocalFsBlobStore`.

    Layout:

      * `<root>/staging/<scope_digest>/<encoded_key>/<version>/parts/<offset>.part`
        — upload parts, written `:exclusive` for idempotency by
        `(reservation, offset)`.
      * `<root>/staging/.../meta.json` — the in-flight reservation's
        `createdAt` (Reserved entries live *only* here — eviction never
        scans this tree, so they can never be eviction candidates).
      * `<root>/committed/<scope_digest>/<encoded_key>/{meta.json,blob}`
        — the atomic, visible-only-after-finalize committed entry.

    `reservation` is a plain map fully derivable from `(scope, key,
    version)` — no server-side process holds it, so it round-trips through
    an HTTP boundary as an opaque token with no hidden coupling.
    """

    @behaviour CrestCiGateway.Results.CacheStore

    @enforce_keys [:root]
    defstruct [:root]

    @type t :: %__MODULE__{root: String.t()}

    @spec new(String.t()) :: t()
    def new(root) when is_binary(root), do: %__MODULE__{root: root}

    @impl CrestCiGateway.Results.CacheStore
    def reserve(%__MODULE__{root: root}, key, version, %CacheScope{} = scope) do
      scope_digest = CacheScope.digest(scope)
      encoded_key = encode_key(key)

      if File.exists?(committed_meta_path(root, scope_digest, encoded_key)) do
        {:error, :already_committed}
      else
        dir = staging_dir(root, scope_digest, encoded_key, version)
        File.mkdir_p!(Path.join(dir, "parts"))

        created_at = next_timestamp()

        File.write!(
          Path.join(dir, "meta.json"),
          Jason.encode!(%{"createdAt" => created_at})
        )

        {:ok,
         %{
           root: root,
           scope_digest: scope_digest,
           encoded_key: encoded_key,
           key: key,
           version: version
         }}
      end
    end

    @impl CrestCiGateway.Results.CacheStore
    def upload(%__MODULE__{}, reservation, offset, content) do
      parts_dir =
        Path.join(
          staging_dir(
            reservation.root,
            reservation.scope_digest,
            reservation.encoded_key,
            reservation.version
          ),
          "parts"
        )

      path = Path.join(parts_dir, "#{offset}.part")

      case File.open(path, [:write, :exclusive]) do
        {:ok, io} ->
          IO.binwrite(io, content)
          File.close(io)
          :ok

        {:error, :eexist} ->
          # Idempotent by (reservation, offset): already stored, no-op.
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl CrestCiGateway.Results.CacheStore
    def commit(%__MODULE__{root: root}, reservation, declared_size) do
      dir =
        staging_dir(root, reservation.scope_digest, reservation.encoded_key, reservation.version)

      assembled = assemble_parts(Path.join(dir, "parts"))

      if byte_size(assembled) == declared_size do
        %{"createdAt" => created_at} =
          dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

        {:ok, entry} =
          CacheEntry.new(
            reservation.key,
            reservation.scope_digest,
            declared_size,
            :committed,
            reservation.version,
            created_at,
            created_at
          )

        committed = committed_dir(root, reservation.scope_digest, reservation.encoded_key)
        File.mkdir_p!(committed)
        File.write!(Path.join(committed, "blob"), assembled)
        File.write!(Path.join(committed, "meta.json"), Jason.encode!(CacheEntry.to_wire(entry)))

        {:ok, entry}
      else
        {:error, :size_mismatch}
      end
    end

    @impl CrestCiGateway.Results.CacheStore
    def lookup(%__MODULE__{root: root}, key, restore_keys, scope_chain) do
      candidates =
        scope_chain
        |> Enum.map(&CacheScope.digest/1)
        |> Enum.flat_map(&committed_entries(root, &1))

      case RestoreKeyResolver.resolve(candidates, key, restore_keys) do
        {:ok, entry} ->
          touched = CacheEntry.touch(entry, next_timestamp())
          persist_touch!(root, touched)
          {:ok, touched, read_blob(root, touched)}

        :miss ->
          :miss
      end
    end

    @impl CrestCiGateway.Results.CacheStore
    def evict(%__MODULE__{root: root}, byte_budget) do
      {:ok, victims} = LruEvictor.evict(all_committed_entries(root), byte_budget)
      Enum.each(victims, &delete_committed!(root, &1))
      {:ok, victims}
    end

    # -- internal ------------------------------------------------------------

    defp encode_key(key), do: Base.url_encode64(key, padding: false)

    defp staging_dir(root, scope_digest, encoded_key, version),
      do: Path.join([root, "staging", scope_digest, encoded_key, version])

    defp committed_dir(root, scope_digest, encoded_key),
      do: Path.join([root, "committed", scope_digest, encoded_key])

    defp committed_meta_path(root, scope_digest, encoded_key),
      do: Path.join(committed_dir(root, scope_digest, encoded_key), "meta.json")

    defp assemble_parts(parts_dir) do
      case File.ls(parts_dir) do
        {:ok, files} ->
          files
          |> Enum.map(&parse_offset/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
          |> Enum.map(fn offset ->
            {:ok, content} = File.read(Path.join(parts_dir, "#{offset}.part"))
            content
          end)
          |> IO.iodata_to_binary()

        {:error, _reason} ->
          ""
      end
    end

    @offset_pattern ~r/^(\d+)\.part$/

    defp parse_offset(filename) do
      case Regex.run(@offset_pattern, filename) do
        [_, offset_str] -> String.to_integer(offset_str)
        _ -> nil
      end
    end

    defp committed_entries(root, scope_digest) do
      dir = Path.join([root, "committed", scope_digest])

      case File.ls(dir) do
        {:ok, encoded_keys} ->
          Enum.map(encoded_keys, fn encoded_key ->
            {:ok, wire} =
              Path.join([dir, encoded_key, "meta.json"]) |> File.read!() |> Jason.decode()

            {:ok, entry} = CacheEntry.from_wire(wire)
            entry
          end)

        {:error, _reason} ->
          []
      end
    end

    defp all_committed_entries(root) do
      base = Path.join(root, "committed")

      case File.ls(base) do
        {:ok, scope_digests} -> Enum.flat_map(scope_digests, &committed_entries(root, &1))
        {:error, _reason} -> []
      end
    end

    defp persist_touch!(root, %CacheEntry{} = entry) do
      committed = committed_dir(root, entry.scope, encode_key(entry.key))
      File.write!(Path.join(committed, "meta.json"), Jason.encode!(CacheEntry.to_wire(entry)))
    end

    defp read_blob(root, %CacheEntry{} = entry) do
      committed = committed_dir(root, entry.scope, encode_key(entry.key))
      File.read!(Path.join(committed, "blob"))
    end

    defp delete_committed!(root, %CacheEntry{} = entry) do
      File.rm_rf!(committed_dir(root, entry.scope, encode_key(entry.key)))
    end

    # Strictly increasing on every call within this store, regardless of
    # wall-clock resolution — the monotonic-integer suffix is what "most
    # recent" / "oldest lastUsedAt" comparisons key off, so the semantics
    # this suite proves never depend on real-time sleeps or clock jitter.
    defp next_timestamp do
      seq = System.unique_integer([:monotonic, :positive])
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      "#{ts}-#{String.pad_leading(Integer.to_string(seq), 12, "0")}"
    end
  end

  # ===========================================================================
  # Thin HTTP transport: translates JSON <-> CacheStore port calls only
  # ===========================================================================

  defmodule CacheHttpServer do
    @moduledoc """
    Adapter over Plug + Bandit exposing `port.Results.CacheStore` for a
    real socket. Owns HTTP concerns only (routing, JSON (de)serialization,
    status codes) — every behavioral decision (match selection, eviction
    order, atomic finalize) is delegated to `CacheStore`, never
    reimplemented here.

    Endpoints:

      * `POST /cache/reserve` -> `{"uploadRef", ...}` | 409 already_committed
      * `POST /cache/upload`  -> 200 (idempotent by (uploadRef, offset))
      * `POST /cache/commit`  -> `{"entry", ...}` | 422 size_mismatch
      * `POST /cache/lookup`  -> `{"entry", "content"}` | 200 `{"status":"miss"}`
        (a miss is a normal, well-formed response — never an error status)
      * `POST /cache/evict`   -> `{"evicted", [...]}`
    """

    @behaviour Plug

    alias CrestCiGateway.Results.CacheStore

    @impl Plug
    def init(store), do: store

    @impl Plug
    def call(conn, store) do
      conn = Plug.Conn.fetch_query_params(conn)
      dispatch(conn.method, conn.path_info, conn, store)
    end

    @spec serve(struct(), :inet.port_number()) :: {:ok, pid()} | {:error, term()}
    def serve(store, port) when is_integer(port) and port >= 0 do
      Bandit.start_link(plug: {__MODULE__, store}, port: port, startup_log: false)
    end

    @spec bound_port(pid()) :: {:ok, :inet.port_number()} | {:error, term()}
    def bound_port(server) when is_pid(server) do
      case ThousandIsland.listener_info(server) do
        {:ok, {_address, port}} -> {:ok, port}
        other -> {:error, other}
      end
    end

    defp dispatch("POST", ["cache", "reserve"], conn, store), do: handle_reserve(conn, store)
    defp dispatch("POST", ["cache", "upload"], conn, store), do: handle_upload(conn, store)
    defp dispatch("POST", ["cache", "commit"], conn, store), do: handle_commit(conn, store)
    defp dispatch("POST", ["cache", "lookup"], conn, store), do: handle_lookup(conn, store)
    defp dispatch("POST", ["cache", "evict"], conn, store), do: handle_evict(conn, store)

    defp dispatch(method, path_info, conn, _store) do
      send_json(conn, 500, %{
        "error" => "unknown_route",
        "method" => method,
        "path" => Enum.join(path_info, "/")
      })
    end

    defp handle_reserve(conn, store) do
      with {:ok, body, conn} <- read_json_body(conn),
           {:ok, scope} <- CacheScope.from_wire(body["scope"]) do
        case CacheStore.reserve(store, body["key"], body["version"], scope) do
          {:ok, reservation} -> send_json(conn, 201, %{"uploadRef" => encode_ref(reservation)})
          {:error, :already_committed} -> send_json(conn, 409, %{"error" => "already_committed"})
        end
      else
        _ -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_upload(conn, store) do
      with {:ok, body, conn} <- read_json_body(conn) do
        reservation = decode_ref(body["uploadRef"])
        content = Base.decode64!(body["content"])
        :ok = CacheStore.upload(store, reservation, body["offset"], content)
        send_json(conn, 200, %{"status" => "ok"})
      else
        _ -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_commit(conn, store) do
      with {:ok, body, conn} <- read_json_body(conn) do
        reservation = decode_ref(body["uploadRef"])

        case CacheStore.commit(store, reservation, body["declaredSize"]) do
          {:ok, entry} -> send_json(conn, 200, %{"entry" => CacheEntry.to_wire(entry)})
          {:error, :size_mismatch} -> send_json(conn, 422, %{"error" => "size_mismatch"})
        end
      else
        _ -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_lookup(conn, store) do
      with {:ok, body, conn} <- read_json_body(conn) do
        restore_keys = Map.get(body, "restoreKeys", [])

        scope_chain =
          Enum.map(body["scopeChain"], fn wire ->
            {:ok, scope} = CacheScope.from_wire(wire)
            scope
          end)

        case CacheStore.lookup(store, body["key"], restore_keys, scope_chain) do
          {:ok, entry, content} ->
            send_json(conn, 200, %{
              "entry" => CacheEntry.to_wire(entry),
              "content" => Base.encode64(content)
            })

          :miss ->
            send_json(conn, 200, %{"status" => "miss"})
        end
      else
        _ -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_evict(conn, store) do
      with {:ok, body, conn} <- read_json_body(conn) do
        {:ok, victims} = CacheStore.evict(store, body["byteBudget"])
        send_json(conn, 200, %{"evicted" => Enum.map(victims, &CacheEntry.to_wire/1)})
      else
        _ -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    # A reservation is a plain map fully derivable from (scope, key,
    # version) — no server-side process holds it, so the HTTP boundary
    # can round-trip it as an opaque base64 token with an explicit,
    # closed key set (never dynamically atomizing client input).
    defp encode_ref(reservation) do
      reservation
      |> Map.take([:root, :scope_digest, :encoded_key, :key, :version])
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end

    defp decode_ref(token) do
      %{
        "root" => root,
        "scope_digest" => scope_digest,
        "encoded_key" => encoded_key,
        "key" => key,
        "version" => version
      } = token |> Base.url_decode64!(padding: false) |> Jason.decode!()

      %{
        root: root,
        scope_digest: scope_digest,
        encoded_key: encoded_key,
        key: key,
        version: version
      }
    end

    defp read_json_body(conn) do
      case Plug.Conn.read_body(conn) do
        {:ok, "", conn} -> {:ok, %{}, conn}
        {:ok, raw, conn} -> with {:ok, decoded} <- Jason.decode(raw), do: {:ok, decoded, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  # ===========================================================================
  # Test HTTP client helpers
  # ===========================================================================

  # Boots an isolated gateway-replica-style HTTP endpoint over its own
  # temp-dir-backed store and registers its teardown. Each call yields a
  # store with no entries in common with any other call's store — cases
  # that need to reason about `evict/2`'s store-wide budget (which has no
  # scope parameter, per the port contract) get their own instance so
  # earlier cases' committed entries can never leak into their budget math.
  defp boot_server! do
    root = Path.join(System.tmp_dir!(), "cache_semantics_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    store = LocalFsCacheStore.new(root)
    {:ok, server} = CacheHttpServer.serve(store, 0)
    {:ok, port} = CacheHttpServer.bound_port(server)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :normal)
      File.rm_rf!(root)
    end)

    "http://127.0.0.1:#{port}"
  end

  setup do
    %{base: boot_server!()}
  end

  defp scope_wire(repo, ref), do: %{"repo" => repo, "ref" => ref}

  defp put_commit!(base, key, version, scope, content) do
    reserve_resp =
      Req.post!(base <> "/cache/reserve",
        json: %{"key" => key, "version" => version, "scope" => scope},
        retry: false
      )

    assert reserve_resp.status == 201
    upload_ref = reserve_resp.body["uploadRef"]

    upload_resp =
      Req.post!(base <> "/cache/upload",
        json: %{"uploadRef" => upload_ref, "offset" => 0, "content" => Base.encode64(content)},
        retry: false
      )

    assert upload_resp.status == 200

    commit_resp =
      Req.post!(base <> "/cache/commit",
        json: %{"uploadRef" => upload_ref, "declaredSize" => byte_size(content)},
        retry: false
      )

    assert commit_resp.status == 200
    commit_resp.body["entry"]
  end

  defp reserve_only!(base, key, version, scope) do
    resp =
      Req.post!(base <> "/cache/reserve",
        json: %{"key" => key, "version" => version, "scope" => scope},
        retry: false
      )

    assert resp.status == 201
    resp.body["uploadRef"]
  end

  defp lookup!(base, key, restore_keys, scope_chain) do
    Req.post!(base <> "/cache/lookup",
      json: %{"key" => key, "restoreKeys" => restore_keys, "scopeChain" => scope_chain},
      retry: false
    )
  end

  # ===========================================================================
  # The behavioral suite
  # ===========================================================================

  test "GitHub restore-key / scope-chain semantics plus LRU eviction, over real HTTP", %{
    base: base
  } do
    feature_scope = scope_wire("acme/widgets", "refs/heads/feature-x")
    main_scope = scope_wire("acme/widgets", "refs/heads/main")
    other_feature_scope = scope_wire("acme/widgets", "refs/heads/feature-y")

    {:ok, feature_struct} = CacheScope.new("refs/heads/feature-x", "acme/widgets")
    {:ok, chain_structs} = CacheScope.lookup_chain(feature_struct, "refs/heads/main")
    chain_wire = Enum.map(chain_structs, &CacheScope.to_wire/1)
    assert chain_wire == [feature_scope, main_scope]

    exact_hits = 0
    prefix_hits = 0
    wrong_scope_hits = 0
    soft_misses = 0
    lru_order_violations = 0

    # -- (1) exact-key hit ---------------------------------------------------

    put_commit!(base, "build-cache-exact", "v1", feature_scope, "exact-bytes")

    resp = lookup!(base, "build-cache-exact", [], chain_wire)
    assert resp.status == 200
    assert resp.body["entry"]["key"] == "build-cache-exact"
    assert Base.decode64!(resp.body["content"]) == "exact-bytes"
    exact_hits = exact_hits + 1

    # -- (2) restore-key prefix hit, most recent of two matches --------------

    put_commit!(base, "deps-otp27-aaa111", "v1", feature_scope, "older-deps-blob")
    put_commit!(base, "deps-otp27-bbb222", "v1", feature_scope, "newer-deps-blob")

    resp = lookup!(base, "deps-otp27-does-not-exist", ["deps-otp27-"], chain_wire)
    assert resp.status == 200
    assert resp.body["entry"]["key"] == "deps-otp27-bbb222"
    assert Base.decode64!(resp.body["content"]) == "newer-deps-blob"
    prefix_hits = prefix_hits + 1

    # -- (3) matching key lives only in a scope NOT in the chain -> miss -----

    put_commit!(
      base,
      "shared-key-wrong-scope",
      "v1",
      other_feature_scope,
      "should-never-be-served"
    )

    resp = lookup!(base, "shared-key-wrong-scope", [], chain_wire)

    {wrong_scope_hits, soft_misses} =
      if resp.status == 200 and Map.has_key?(resp.body, "entry") do
        flunk("scope isolation violated: served an entry from a scope outside the lookup chain")
        {wrong_scope_hits + 1, soft_misses}
      else
        assert resp.status == 200
        assert resp.body["status"] == "miss"
        {wrong_scope_hits, soft_misses + 1}
      end

    # -- (4) default-branch fallback hit from a feature-branch scope chain ---

    put_commit!(base, "fallback-deps", "v1", main_scope, "fallback-bytes")

    resp = lookup!(base, "fallback-deps", [], chain_wire)
    assert resp.status == 200
    assert resp.body["entry"]["key"] == "fallback-deps"
    assert Base.decode64!(resp.body["content"]) == "fallback-bytes"
    exact_hits = exact_hits + 1

    # -- (5) miss returns the soft-miss shape, not an error -------------------

    resp = lookup!(base, "never-existed-key", ["never-matches-"], chain_wire)
    assert resp.status == 200
    assert resp.body["status"] == "miss"
    refute Map.has_key?(resp.body, "error")
    soft_misses = soft_misses + 1

    # -- (6) fill past a small byte budget; evict; Reserved entries survive --
    #
    # A dedicated store/server instance: evict/2 has no scope parameter
    # (it is store-wide by port contract, mirroring FakeCacheStore.evict/2
    # in cache_store_test.exs), so the budget below must not have to
    # account for bytes committed by cases (1)-(5) on the shared `base`.

    lru_base = boot_server!()
    lru_scope = scope_wire("acme/lru-corp", "refs/heads/main")

    e1 = put_commit!(lru_base, "lru-a", "v1", lru_scope, String.duplicate("a", 50))
    e2 = put_commit!(lru_base, "lru-b", "v1", lru_scope, String.duplicate("b", 50))
    e3 = put_commit!(lru_base, "lru-c", "v1", lru_scope, String.duplicate("c", 50))

    # An in-flight (Reserved, never committed) upload alongside the
    # committed entries above — eviction must never touch it.
    in_flight_ref = reserve_only!(lru_base, "lru-in-flight", "v1", lru_scope)

    upload_resp =
      Req.post!(lru_base <> "/cache/upload",
        json: %{
          "uploadRef" => in_flight_ref,
          "offset" => 0,
          "content" => Base.encode64("in-flight-bytes")
        },
        retry: false
      )

    assert upload_resp.status == 200

    evict_resp = Req.post!(lru_base <> "/cache/evict", json: %{"byteBudget" => 60}, retry: false)
    assert evict_resp.status == 200

    evicted_keys = Enum.map(evict_resp.body["evicted"], & &1["key"])

    expected_oldest_first = [e1["key"], e2["key"]]

    lru_order_violations =
      if evicted_keys == expected_oldest_first do
        lru_order_violations
      else
        lru_order_violations + 1
      end

    assert evicted_keys == expected_oldest_first
    refute e3["key"] in evicted_keys

    # The most-recently-used committed entry survives and is still servable.
    resp = lookup!(lru_base, e3["key"], [], [lru_scope])
    assert resp.status == 200
    assert resp.body["entry"]["key"] == e3["key"]

    # The evicted entries are gone from lookup.
    resp = lookup!(lru_base, e1["key"], [], [lru_scope])
    assert resp.body["status"] == "miss"

    # The Reserved (in-flight) upload was never an eviction candidate: its
    # staging files are untouched, so completing the commit afterwards
    # still succeeds.
    commit_resp =
      Req.post!(lru_base <> "/cache/commit",
        json: %{"uploadRef" => in_flight_ref, "declaredSize" => byte_size("in-flight-bytes")},
        retry: false
      )

    assert commit_resp.status == 200
    assert commit_resp.body["entry"]["key"] == "lru-in-flight"

    IO.puts(
      "cache_exact_hits=#{exact_hits} prefix_hits=#{prefix_hits} wrong_scope_hits=#{wrong_scope_hits} " <>
        "soft_misses=#{soft_misses} lru_order_violations=#{lru_order_violations}"
    )
  end
end
