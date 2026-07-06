defmodule CrestCiGateway.Results.CacheApiTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias CrestCiGateway.Results.CacheApi
  alias CrestCiGateway.Results.CacheApi.Deps
  alias CrestCiGateway.Results.CacheEntry
  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.RunnerToken
  alias CrestCiGateway.TokenIssuer

  @signing_key "test-signing-key"

  # A minimal in-memory fake implementing `port.Results.CacheStore`. Exact-key
  # lookup only — restore-key / prefix semantics are `RestoreKeyResolver`'s
  # own resource and are proven there; this fixture exists only to prove
  # `CacheApi` wires HTTP <-> the `CacheStore` port faithfully. Never becomes
  # production code.
  defmodule FakeCacheStore do
    @behaviour CrestCiGateway.Results.CacheStore

    defstruct [:agent]

    def new do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{committed: %{}, contents: %{}, blobs: %{}, reserve_calls: 0}
        end)

      %__MODULE__{agent: agent}
    end

    def reserve_call_count(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.reserve_calls)

    @impl CrestCiGateway.Results.CacheStore
    def reserve(%__MODULE__{agent: agent}, key, version, scope) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | reserve_calls: state.reserve_calls + 1}
        scope_digest = CacheScope.digest(scope)

        if Map.has_key?(state.committed, {scope_digest, key}) do
          {{:error, :already_committed}, state}
        else
          {{:ok, {key, version, scope_digest, make_ref()}}, state}
        end
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def upload(%__MODULE__{agent: agent}, reservation, offset, content) do
      Agent.update(agent, fn state ->
        %{state | blobs: Map.put_new(state.blobs, {reservation, offset}, content)}
      end)

      :ok
    end

    @impl CrestCiGateway.Results.CacheStore
    def commit(
          %__MODULE__{agent: agent},
          {key, version, scope_digest, _tag} = reservation,
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
          now = "2026-01-01T00:00:00Z"

          {:ok, entry} =
            CacheEntry.new(key, scope_digest, declared_size, :committed, version, now, now)

          new_state = %{
            state
            | committed: Map.put(state.committed, {scope_digest, key}, entry),
              contents: Map.put(state.contents, {scope_digest, key}, assembled)
          }

          {{:ok, entry}, new_state}
        else
          {{:error, :size_mismatch}, state}
        end
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def lookup(%__MODULE__{agent: agent}, key, _restore_keys, scope_chain) do
      Agent.get(agent, fn state ->
        scope_chain
        |> Enum.map(&CacheScope.digest/1)
        |> Enum.find_value(:miss, fn digest ->
          case Map.fetch(state.committed, {digest, key}) do
            {:ok, entry} -> {:ok, entry, Map.fetch!(state.contents, {digest, key})}
            :error -> nil
          end
        end)
      end)
    end

    @impl CrestCiGateway.Results.CacheStore
    def evict(%__MODULE__{}, _byte_budget), do: {:ok, []}
  end

  defp stub_deps(store, overrides \\ %{}) do
    defaults = %{
      store: store,
      signing_key: @signing_key,
      verify_token: fn _key, token ->
        case Jason.decode(token) do
          {:ok, %{"job_name" => j, "exp" => exp}} ->
            if exp < System.system_time(:second) do
              {:error, :expired}
            else
              {:ok, %{job_name: j}}
            end

          _other ->
            {:error, :invalid}
        end
      end
    }

    struct!(Deps, Map.merge(defaults, overrides))
  end

  defp stub_token(job_name \\ "job-a", ttl_seconds \\ 3600) do
    Jason.encode!(%{"job_name" => job_name, "exp" => System.system_time(:second) + ttl_seconds})
  end

  defp with_bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp post_json(deps, path, token, body) do
    conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> maybe_bearer(token)
    |> CacheApi.call(deps)
  end

  defp maybe_bearer(conn, nil), do: conn
  defp maybe_bearer(conn, token), do: with_bearer(conn, token)

  defp scope_wire(repo, ref), do: %{"repo" => repo, "ref" => ref}

  # ===========================================================================
  # Auth: verified before any collaborator is touched
  # ===========================================================================

  test "unknown route returns 500" do
    deps = stub_deps(FakeCacheStore.new())
    resp = conn(:get, "/totally/unknown") |> with_bearer(stub_token()) |> CacheApi.call(deps)
    assert resp.status == 500
  end

  test "missing bearer token is rejected (401) and never touches the store" do
    store = FakeCacheStore.new()
    deps = stub_deps(store)

    resp = post_json(deps, "/cache/reserve", nil, %{"key" => "k", "version" => "v1"})

    assert resp.status == 401
    assert FakeCacheStore.reserve_call_count(store) == 0
  end

  test "invalid bearer token is rejected (401) and never touches the store" do
    store = FakeCacheStore.new()
    deps = stub_deps(store)

    resp =
      post_json(deps, "/cache/reserve", "not-a-real-token", %{
        "key" => "k",
        "version" => "v1",
        "scope" => scope_wire("acme/widgets", "refs/heads/main")
      })

    assert resp.status == 401
    assert FakeCacheStore.reserve_call_count(store) == 0
  end

  test "expired bearer token is rejected (401)" do
    store = FakeCacheStore.new()
    deps = stub_deps(store)
    expired = Jason.encode!(%{"job_name" => "job-a", "exp" => System.system_time(:second) - 10})

    resp =
      post_json(deps, "/cache/reserve", expired, %{
        "key" => "k",
        "version" => "v1",
        "scope" => scope_wire("acme/widgets", "refs/heads/main")
      })

    assert resp.status == 401
    assert FakeCacheStore.reserve_call_count(store) == 0
  end

  # ===========================================================================
  # POST /cache/reserve
  # ===========================================================================

  test "reserve with a valid token and scope mints an opaque uploadRef (201)" do
    deps = stub_deps(FakeCacheStore.new())

    resp =
      post_json(deps, "/cache/reserve", stub_token(), %{
        "key" => "deps-otp27-a1b2c3",
        "version" => "v1",
        "scope" => scope_wire("acme/widgets", "refs/heads/main")
      })

    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)
    assert is_binary(body["uploadRef"])
    assert body["uploadRef"] != ""
  end

  test "reserve rejects an already-committed key (409)" do
    store = FakeCacheStore.new()
    deps = stub_deps(store)
    scope = scope_wire("acme/widgets", "refs/heads/main")

    upload_ref = reserve!(deps, "deps-key", "v1", scope)
    upload!(deps, upload_ref, 0, "hello")
    commit!(deps, upload_ref, 5)

    resp =
      post_json(deps, "/cache/reserve", stub_token(), %{
        "key" => "deps-key",
        "version" => "v2",
        "scope" => scope
      })

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"] == "already_committed"
  end

  test "reserve with a malformed body (missing scope) is rejected (400)" do
    deps = stub_deps(FakeCacheStore.new())

    resp =
      post_json(deps, "/cache/reserve", stub_token(), %{"key" => "k", "version" => "v1"})

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"] == "malformed_body"
  end

  # ===========================================================================
  # POST /cache/upload
  # ===========================================================================

  test "upload is idempotent by (uploadRef, offset)" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/main")
    upload_ref = reserve!(deps, "deps-idempotent", "v1", scope)

    resp1 = upload!(deps, upload_ref, 0, "hello")
    resp2 = upload!(deps, upload_ref, 0, "hello")

    assert resp1.status == 200
    assert resp2.status == 200
  end

  test "upload with a garbage uploadRef is rejected (400), never a crash" do
    deps = stub_deps(FakeCacheStore.new())

    resp =
      post_json(deps, "/cache/upload", stub_token(), %{
        "uploadRef" => "not-a-real-ref",
        "offset" => 0,
        "content" => Base.encode64("hi")
      })

    assert resp.status == 400
  end

  # ===========================================================================
  # POST /cache/commit
  # ===========================================================================

  test "commit finalizes an entry (200) with the wire-shaped CacheEntry" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/main")
    upload_ref = reserve!(deps, "deps-commit", "v1", scope)
    upload!(deps, upload_ref, 0, "cached-bytes")

    resp = commit!(deps, upload_ref, byte_size("cached-bytes"))

    assert resp.status == 200
    entry = Jason.decode!(resp.resp_body)["entry"]
    assert entry["key"] == "deps-commit"
    assert entry["state"] == "Committed"
    assert entry["sizeBytes"] == byte_size("cached-bytes")
  end

  test "commit rejects a size mismatch (422)" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/main")
    upload_ref = reserve!(deps, "deps-bad-size", "v1", scope)
    upload!(deps, upload_ref, 0, "hello")

    resp = commit!(deps, upload_ref, 999)

    assert resp.status == 422
    assert Jason.decode!(resp.resp_body)["error"] == "size_mismatch"
  end

  # ===========================================================================
  # POST /cache/lookup
  # ===========================================================================

  test "lookup on a committed key returns the entry and its bytes (200)" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/main")
    upload_ref = reserve!(deps, "deps-hit", "v1", scope)
    upload!(deps, upload_ref, 0, "cached-bytes")
    commit!(deps, upload_ref, byte_size("cached-bytes"))

    resp =
      post_json(deps, "/cache/lookup", stub_token(), %{
        "key" => "deps-hit",
        "restoreKeys" => [],
        "scopeChain" => [scope]
      })

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["entry"]["key"] == "deps-hit"
    assert Base.decode64!(body["content"]) == "cached-bytes"
  end

  test "lookup on an unknown key is a soft miss (200), never an error" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/main")

    resp =
      post_json(deps, "/cache/lookup", stub_token(), %{
        "key" => "never-committed",
        "restoreKeys" => ["deps-"],
        "scopeChain" => [scope]
      })

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["status"] == "miss"
    refute Map.has_key?(body, "error")
  end

  # ===========================================================================
  # Full round trip
  # ===========================================================================

  test "reserve -> upload -> commit -> lookup round trips real bytes over HTTP" do
    deps = stub_deps(FakeCacheStore.new())
    scope = scope_wire("acme/widgets", "refs/heads/feature-x")

    upload_ref = reserve!(deps, "build-cache-exact", "v1", scope)
    upload!(deps, upload_ref, 0, "exact-")
    upload!(deps, upload_ref, 6, "bytes")
    commit_resp = commit!(deps, upload_ref, byte_size("exact-bytes"))
    assert commit_resp.status == 200

    resp =
      post_json(deps, "/cache/lookup", stub_token(), %{
        "key" => "build-cache-exact",
        "restoreKeys" => [],
        "scopeChain" => [scope]
      })

    body = Jason.decode!(resp.resp_body)
    assert body["entry"]["key"] == "build-cache-exact"
    assert Base.decode64!(body["content"]) == "exact-bytes"
  end

  # ===========================================================================
  # Real TokenIssuer / RunnerToken integration (not the JSON stub)
  # ===========================================================================

  test "authenticates against the real CrestCiGateway.TokenIssuer" do
    store = FakeCacheStore.new()

    deps =
      stub_deps(store, %{
        verify_token: &TokenIssuer.verify/2
      })

    %RunnerToken{token: token} =
      TokenIssuer.mint(@signing_key, "runner-1", "job-a", System.system_time(:second) + 3600)

    resp =
      post_json(deps, "/cache/reserve", token, %{
        "key" => "deps-real-token",
        "version" => "v1",
        "scope" => scope_wire("acme/widgets", "refs/heads/main")
      })

    assert resp.status == 201
  end

  test "rejects an expired real RunnerToken (401)" do
    store = FakeCacheStore.new()
    deps = stub_deps(store, %{verify_token: &TokenIssuer.verify/2})

    %RunnerToken{token: token} =
      TokenIssuer.mint(@signing_key, "runner-1", "job-a", System.system_time(:second) - 1)

    resp =
      post_json(deps, "/cache/reserve", token, %{
        "key" => "deps-real-token-expired",
        "version" => "v1",
        "scope" => scope_wire("acme/widgets", "refs/heads/main")
      })

    assert resp.status == 401
    assert FakeCacheStore.reserve_call_count(store) == 0
  end

  # ===========================================================================
  # Test helpers wired against the real Plug pipeline
  # ===========================================================================

  defp reserve!(deps, key, version, scope) do
    resp =
      post_json(deps, "/cache/reserve", stub_token(), %{
        "key" => key,
        "version" => version,
        "scope" => scope
      })

    assert resp.status == 201
    Jason.decode!(resp.resp_body)["uploadRef"]
  end

  defp upload!(deps, upload_ref, offset, content) do
    post_json(deps, "/cache/upload", stub_token(), %{
      "uploadRef" => upload_ref,
      "offset" => offset,
      "content" => Base.encode64(content)
    })
  end

  defp commit!(deps, upload_ref, declared_size) do
    post_json(deps, "/cache/commit", stub_token(), %{
      "uploadRef" => upload_ref,
      "declaredSize" => declared_size
    })
  end
end
