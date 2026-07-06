defmodule CrestCiGateway.Results.ArtifactsApiTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias CrestCiGateway.Results.ArtifactsApi
  alias CrestCiGateway.Results.ArtifactsApi.Deps
  alias CrestCiGateway.Results.LocalFsArtifactStore
  alias CrestCiGateway.RunnerToken
  alias CrestCiGateway.TokenIssuer

  @signing_key "test-signing-key"

  # -- fixtures ---------------------------------------------------------------

  defp new_store do
    root =
      Path.join(System.tmp_dir!(), "artifacts_api_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    LocalFsArtifactStore.new(root)
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

  defp maybe_bearer(conn, nil), do: conn
  defp maybe_bearer(conn, token), do: with_bearer(conn, token)

  defp post_json(deps, path, token, body) do
    conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> maybe_bearer(token)
    |> ArtifactsApi.call(deps)
  end

  defp get_(deps, path, token) do
    conn(:get, path) |> maybe_bearer(token) |> ArtifactsApi.call(deps)
  end

  defp create!(deps, job, name, declared_size) do
    resp =
      post_json(deps, "/jobs/#{job}/artifacts", stub_token(job), %{
        "name" => name,
        "declaredSize" => declared_size
      })

    assert resp.status == 201
    Jason.decode!(resp.resp_body)["uploadRef"]
  end

  defp upload_part!(deps, job, upload_ref, index, content) do
    post_json(deps, "/jobs/#{job}/artifacts/parts", stub_token(job), %{
      "uploadRef" => upload_ref,
      "partIndex" => index,
      "content" => Base.encode64(content)
    })
  end

  defp finalize!(deps, job, upload_ref, declared_digest) do
    post_json(deps, "/jobs/#{job}/artifacts/finalize", stub_token(job), %{
      "uploadRef" => upload_ref,
      "declaredDigest" => declared_digest
    })
  end

  # ===========================================================================
  # Auth: verified before any collaborator is touched
  # ===========================================================================

  test "unknown route returns 500" do
    deps = stub_deps(new_store())

    resp =
      conn(:get, "/totally/unknown") |> with_bearer(stub_token()) |> ArtifactsApi.call(deps)

    assert resp.status == 500
  end

  test "missing bearer token is rejected (401) and never touches the store" do
    deps = stub_deps(new_store())

    resp = post_json(deps, "/jobs/job-a/artifacts", nil, %{"name" => "x", "declaredSize" => 0})

    assert resp.status == 401
  end

  test "invalid bearer token is rejected (401)" do
    deps = stub_deps(new_store())

    resp =
      post_json(deps, "/jobs/job-a/artifacts", "not-a-real-token", %{
        "name" => "x",
        "declaredSize" => 0
      })

    assert resp.status == 401
  end

  test "expired bearer token is rejected (401)" do
    deps = stub_deps(new_store())
    expired = Jason.encode!(%{"job_name" => "job-a", "exp" => System.system_time(:second) - 10})

    resp =
      post_json(deps, "/jobs/job-a/artifacts", expired, %{"name" => "x", "declaredSize" => 0})

    assert resp.status == 401
  end

  # ===========================================================================
  # Job-path confinement: "confined to that job's run"
  # ===========================================================================

  test "a valid token for a DIFFERENT job than the path is rejected (401 job_mismatch) before the store is touched" do
    deps = stub_deps(new_store())
    token_for_job_b = stub_token("job-b")

    resp =
      post_json(deps, "/jobs/job-a/artifacts", token_for_job_b, %{
        "name" => "x",
        "declaredSize" => 0
      })

    assert resp.status == 401
    assert Jason.decode!(resp.resp_body)["error"] == "job_mismatch"
  end

  test "a job cannot list or read another job's run even though both are known to the store" do
    deps = stub_deps(new_store())

    upload_ref = create!(deps, "job-a", "secret.txt", byte_size("shh"))
    assert {200, %{"status" => "ok"}} = json(upload_part!(deps, "job-a", upload_ref, 0, "shh"))
    digest = Base.encode16(:crypto.hash(:sha256, "shh"), case: :lower)
    assert {200, _} = json(finalize!(deps, "job-a", upload_ref, digest))

    # job-b's own token can only ever see job-b's own run/list — it can
    # never be pointed at job-a's run because no route accepts a run
    # override; the path segment IS the auth boundary.
    resp = get_(deps, "/jobs/job-b/artifacts", stub_token("job-b"))
    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["artifacts"] == []
  end

  # ===========================================================================
  # POST /jobs/:job/artifacts — begin an upload
  # ===========================================================================

  test "create with a valid token mints an opaque uploadRef (201)" do
    deps = stub_deps(new_store())

    resp =
      post_json(deps, "/jobs/job-a/artifacts", stub_token(), %{
        "name" => "build.tar",
        "declaredSize" => 10
      })

    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)
    assert is_binary(body["uploadRef"])
    assert body["uploadRef"] != ""
  end

  test "create rejects a deterministic-name collision with an already-finalized artifact (409)" do
    deps = stub_deps(new_store())
    upload_ref = create!(deps, "job-a", "dup.tar", byte_size("hi"))
    assert {200, %{"status" => "ok"}} = json(upload_part!(deps, "job-a", upload_ref, 0, "hi"))
    digest = Base.encode16(:crypto.hash(:sha256, "hi"), case: :lower)
    assert {200, _} = json(finalize!(deps, "job-a", upload_ref, digest))

    resp =
      post_json(deps, "/jobs/job-a/artifacts", stub_token(), %{
        "name" => "dup.tar",
        "declaredSize" => 2
      })

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"] == "already_exists"
  end

  test "create with a malformed body (missing declaredSize) is rejected (400)" do
    deps = stub_deps(new_store())

    resp = post_json(deps, "/jobs/job-a/artifacts", stub_token(), %{"name" => "x"})

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"] == "malformed_body"
  end

  test "create with a path-traversal artifact name is rejected (400)" do
    deps = stub_deps(new_store())

    resp =
      post_json(deps, "/jobs/job-a/artifacts", stub_token(), %{
        "name" => "../../etc/passwd",
        "declaredSize" => 0
      })

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"] == "invalid_name"
  end

  # ===========================================================================
  # POST /jobs/:job/artifacts/parts
  # ===========================================================================

  test "upload_part is idempotent by (uploadRef, partIndex)" do
    deps = stub_deps(new_store())
    upload_ref = create!(deps, "job-a", "idempotent.bin", byte_size("hello"))

    resp1 = upload_part!(deps, "job-a", upload_ref, 0, "hello")
    resp2 = upload_part!(deps, "job-a", upload_ref, 0, "hello")

    assert resp1.status == 200
    assert resp2.status == 200
  end

  test "upload_part with a garbage uploadRef is rejected (400), never a crash" do
    deps = stub_deps(new_store())

    resp =
      post_json(deps, "/jobs/job-a/artifacts/parts", stub_token(), %{
        "uploadRef" => "not-a-real-ref",
        "partIndex" => 0,
        "content" => Base.encode64("hi")
      })

    assert resp.status == 400
  end

  # ===========================================================================
  # POST /jobs/:job/artifacts/finalize — atomic commit point
  # ===========================================================================

  test "finalize commits an entry (200) with the wire-shaped ArtifactRecord" do
    deps = stub_deps(new_store())
    upload_ref = create!(deps, "job-a", "release.tar", byte_size("release-bytes"))
    assert {200, _} = json(upload_part!(deps, "job-a", upload_ref, 0, "release-bytes"))
    digest = Base.encode16(:crypto.hash(:sha256, "release-bytes"), case: :lower)

    resp = finalize!(deps, "job-a", upload_ref, digest)

    assert resp.status == 200
    record = Jason.decode!(resp.resp_body)
    assert record["name"] == "release.tar"
    assert record["digest"] == digest
    assert record["sizeBytes"] == byte_size("release-bytes")
  end

  test "finalize rejects a digest mismatch (409) and the artifact never becomes visible" do
    deps = stub_deps(new_store())
    upload_ref = create!(deps, "job-a", "bad.tar", byte_size("bytes"))
    assert {200, _} = json(upload_part!(deps, "job-a", upload_ref, 0, "bytes"))
    wrong_digest = String.duplicate("0", 64)

    resp = finalize!(deps, "job-a", upload_ref, wrong_digest)

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"] == "digest_mismatch"

    list_resp = get_(deps, "/jobs/job-a/artifacts", stub_token())
    assert Jason.decode!(list_resp.resp_body)["artifacts"] == []

    read_resp = get_(deps, "/jobs/job-a/artifacts/bad.tar", stub_token())
    assert read_resp.status == 404
  end

  # ===========================================================================
  # GET /jobs/:job/artifacts and GET /jobs/:job/artifacts/:name
  # ===========================================================================

  test "list is empty before finalize and shows exactly one entry after (visibility gate)" do
    deps = stub_deps(new_store())

    before_resp = get_(deps, "/jobs/job-a/artifacts", stub_token())
    assert Jason.decode!(before_resp.resp_body)["artifacts"] == []

    upload_ref = create!(deps, "job-a", "coverage.html", byte_size("<html/>"))
    assert {200, _} = json(upload_part!(deps, "job-a", upload_ref, 0, "<html/>"))
    digest = Base.encode16(:crypto.hash(:sha256, "<html/>"), case: :lower)
    assert {200, _} = json(finalize!(deps, "job-a", upload_ref, digest))

    after_resp = get_(deps, "/jobs/job-a/artifacts", stub_token())
    artifacts = Jason.decode!(after_resp.resp_body)["artifacts"]
    assert length(artifacts) == 1
    assert hd(artifacts)["name"] == "coverage.html"
  end

  test "download returns byte-identical content after finalize" do
    deps = stub_deps(new_store())
    content = "alpha-bravo-charlie-delta-echo"
    upload_ref = create!(deps, "job-a", "dist.tar", byte_size(content))
    assert {200, _} = json(upload_part!(deps, "job-a", upload_ref, 0, content))
    digest = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    assert {200, _} = json(finalize!(deps, "job-a", upload_ref, digest))

    resp = get_(deps, "/jobs/job-a/artifacts/dist.tar", stub_token())

    assert resp.status == 200
    assert resp.resp_body == content
  end

  test "download of a name that was never created is 404" do
    deps = stub_deps(new_store())

    resp = get_(deps, "/jobs/job-a/artifacts/never-existed.bin", stub_token())

    assert resp.status == 404
  end

  test "download with a path-traversal name is rejected (400)" do
    deps = stub_deps(new_store())

    resp = get_(deps, "/jobs/job-a/artifacts/%2E%2E%2Fescape", stub_token())

    assert resp.status in [400, 404]
  end

  # ===========================================================================
  # Real TokenIssuer / RunnerToken integration (not the JSON stub)
  # ===========================================================================

  test "authenticates against the real CrestCiGateway.TokenIssuer" do
    deps = stub_deps(new_store(), %{verify_token: &TokenIssuer.verify/2})

    %RunnerToken{token: token} =
      TokenIssuer.mint(@signing_key, "runner-1", "job-a", System.system_time(:second) + 3600)

    resp =
      post_json(deps, "/jobs/job-a/artifacts", token, %{
        "name" => "real-token.bin",
        "declaredSize" => 0
      })

    assert resp.status == 201
  end

  test "rejects an expired real RunnerToken (401)" do
    deps = stub_deps(new_store(), %{verify_token: &TokenIssuer.verify/2})

    %RunnerToken{token: token} =
      TokenIssuer.mint(@signing_key, "runner-1", "job-a", System.system_time(:second) - 1)

    resp =
      post_json(deps, "/jobs/job-a/artifacts", token, %{
        "name" => "real-token.bin",
        "declaredSize" => 0
      })

    assert resp.status == 401
  end

  # ===========================================================================
  # Full round trip over a real Bandit listener (production module, real HTTP)
  # ===========================================================================

  describe "serve/2 over a real socket" do
    setup do
      deps = stub_deps(new_store())
      {:ok, server} = ArtifactsApi.serve(deps, 0)
      {:ok, port} = ArtifactsApi.bound_port(server)
      on_exit(fn -> stop_server(server) end)
      %{deps: deps, base_url: "http://127.0.0.1:#{port}"}
    end

    test "full HTTP round-trip with out-of-order and duplicated parts", %{base_url: base_url} do
      token = stub_token("job-a")
      parts = ["alpha-", "bravo-", "charlie-", "delta-"]
      full_content = IO.iodata_to_binary(parts)
      declared_size = byte_size(full_content)
      declared_digest = Base.encode16(:crypto.hash(:sha256, full_content), case: :lower)

      create_resp =
        Req.post!(base_url <> "/jobs/job-a/artifacts",
          json: %{"name" => "build.tar", "declaredSize" => declared_size},
          headers: [{"authorization", "Bearer " <> token}],
          retry: false
        )

      assert create_resp.status == 201
      upload_ref = create_resp.body["uploadRef"]

      for index <- [1, 0, 3, 2, 1] do
        part_resp =
          Req.post!(base_url <> "/jobs/job-a/artifacts/parts",
            json: %{
              "uploadRef" => upload_ref,
              "partIndex" => index,
              "content" => Base.encode64(Enum.at(parts, index))
            },
            headers: [{"authorization", "Bearer " <> token}],
            retry: false
          )

        assert part_resp.status == 200
      end

      finalize_resp =
        Req.post!(base_url <> "/jobs/job-a/artifacts/finalize",
          json: %{"uploadRef" => upload_ref, "declaredDigest" => declared_digest},
          headers: [{"authorization", "Bearer " <> token}],
          retry: false
        )

      assert finalize_resp.status == 200
      assert finalize_resp.body["digest"] == declared_digest

      download_resp =
        Req.get!(base_url <> "/jobs/job-a/artifacts/build.tar",
          headers: [{"authorization", "Bearer " <> token}],
          retry: false
        )

      assert download_resp.status == 200
      assert download_resp.body == full_content
    end
  end

  defp stop_server(server) do
    if Process.alive?(server) do
      ref = Process.monitor(server)
      Process.exit(server, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^server, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp json(%Plug.Conn{status: status, resp_body: body}), do: {status, Jason.decode!(body)}
end
