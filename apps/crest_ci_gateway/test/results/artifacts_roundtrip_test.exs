defmodule CrestCiGateway.Results.ArtifactsRoundtripTest do
  @moduledoc """
  Full HTTP round-trip proof for `port.Results.ArtifactStore` behind a
  job-scoped bearer token: create -> upload out-of-order parts (one
  resent, simulating a runner retry) -> finalize -> list -> download, all
  over a real `Bandit` listener on an ephemeral port, plus the negative
  path (a wrong-digest finalize is rejected and never becomes visible).

  This slice's gateway HTTP surface (`CrestCiGateway.GatewayHttpServer`)
  does not yet expose artifacts routes — only the runner long-poll
  protocol. `ArtifactsHttpAdapter` below is a small, self-contained
  test-only Plug that exposes `CrestCiGateway.Results.ArtifactStore` over
  HTTP purely to prove the store and `CrestCiGateway.TokenIssuer` compose
  correctly end-to-end; it is not a production component and depends on
  nothing but the already-shipped store port/adapter and token issuer.
  """

  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.LocalFsArtifactStore
  alias CrestCiGateway.TokenIssuer

  @signing_key "artifacts-roundtrip-test-signing-key"

  defmodule Deps do
    @moduledoc false
    @enforce_keys [:signing_key, :store]
    defstruct [:signing_key, :store]
  end

  defmodule ArtifactsHttpAdapter do
    @moduledoc false

    @behaviour Plug

    alias CrestCiGateway.Results.ArtifactRecord
    alias CrestCiGateway.Results.ArtifactStore
    alias CrestCiGateway.Results.ArtifactsRoundtripTest.Deps
    alias CrestCiGateway.TokenIssuer

    @impl Plug
    def init(%Deps{} = deps), do: deps

    @impl Plug
    def call(conn, %Deps{} = deps) do
      dispatch(conn.method, conn.path_info, conn, deps)
    end

    # -- routing -----------------------------------------------------------

    defp dispatch("POST", ["runs", run, "artifacts"], conn, deps),
      do: with_auth(conn, deps, &handle_create(&1, &2, &3, run))

    defp dispatch("POST", ["runs", run, "artifacts", "parts"], conn, deps),
      do: with_auth(conn, deps, &handle_upload_part(&1, &2, &3, run))

    defp dispatch("POST", ["runs", run, "artifacts", "finalize"], conn, deps),
      do: with_auth(conn, deps, &handle_finalize(&1, &2, &3, run))

    defp dispatch("GET", ["runs", run, "artifacts"], conn, deps),
      do: with_auth(conn, deps, &handle_list(&1, &2, &3, run))

    defp dispatch("GET", ["runs", run, "artifacts", name], conn, deps),
      do: with_auth(conn, deps, &handle_read(&1, &2, &3, run, name))

    defp dispatch(_method, _path_info, conn, _deps),
      do: send_json(conn, 500, %{"error" => "unknown_route"})

    # -- auth: every route authenticates the bearer token before any store access --

    defp with_auth(conn, deps, handler) do
      case authenticate(conn, deps.signing_key) do
        {:ok, claims} -> handler.(conn, deps, claims)
        {:error, _reason} -> send_json(conn, 401, %{"error" => "unauthorized"})
      end
    end

    defp authenticate(conn, signing_key) do
      with [auth_header | _] <- Plug.Conn.get_req_header(conn, "authorization"),
           "Bearer " <> token <- auth_header do
        TokenIssuer.verify(signing_key, token)
      else
        _other -> {:error, :missing_token}
      end
    end

    # -- handlers ------------------------------------------------------------

    defp handle_create(conn, deps, claims, run) do
      with {:ok, body, conn} <- read_json(conn),
           %{"name" => name, "declaredSize" => declared_size} <- body,
           {:ok, upload_ref} <-
             ArtifactStore.create(deps.store, run, claims.job_name, name, declared_size) do
        send_json(conn, 201, %{"uploadRef" => upload_ref})
      else
        {:error, :already_exists} -> send_json(conn, 409, %{"error" => "already_exists"})
        {:error, _reason} -> send_json(conn, 500, %{"error" => "create_failed"})
        _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_upload_part(conn, deps, _claims, _run) do
      with {:ok, body, conn} <- read_json(conn),
           %{"uploadRef" => upload_ref, "partIndex" => part_index, "content" => encoded} <- body,
           {:ok, content} <- Base.decode64(encoded),
           :ok <- ArtifactStore.upload_part(deps.store, upload_ref, part_index, content) do
        send_json(conn, 200, %{"status" => "ok"})
      else
        :error -> send_json(conn, 400, %{"error" => "malformed_content"})
        {:error, _reason} -> send_json(conn, 500, %{"error" => "upload_failed"})
        _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_finalize(conn, deps, _claims, _run) do
      with {:ok, body, conn} <- read_json(conn),
           %{"uploadRef" => upload_ref, "declaredDigest" => declared_digest} <- body,
           {:ok, record} <- ArtifactStore.finalize(deps.store, upload_ref, declared_digest) do
        send_json(conn, 200, ArtifactRecord.to_wire(record))
      else
        {:error, :digest_mismatch} -> send_json(conn, 409, %{"error" => "digest_mismatch"})
        {:error, :size_mismatch} -> send_json(conn, 409, %{"error" => "size_mismatch"})
        {:error, _reason} -> send_json(conn, 500, %{"error" => "finalize_failed"})
        _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
      end
    end

    defp handle_list(conn, deps, _claims, run) do
      {:ok, records} = ArtifactStore.list(deps.store, run)
      send_json(conn, 200, %{"artifacts" => Enum.map(records, &ArtifactRecord.to_wire/1)})
    end

    defp handle_read(conn, deps, _claims, run, name) do
      case ArtifactStore.read(deps.store, run, name) do
        {:ok, content} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, content)

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "not_found"})
      end
    end

    # -- body / response helpers ---------------------------------------------

    defp read_json(conn) do
      case Plug.Conn.read_body(conn) do
        {:ok, raw, conn} ->
          case Jason.decode(raw) do
            {:ok, decoded} -> {:ok, decoded, conn}
            {:error, _reason} -> {:error, :malformed_json}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  # -- test setup: real Bandit listener on an ephemeral port -----------------

  setup do
    root =
      Path.join(System.tmp_dir!(), "artifacts_roundtrip_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    store = LocalFsArtifactStore.new(root)
    deps = %Deps{signing_key: @signing_key, store: store}

    {:ok, server} =
      Bandit.start_link(plug: {ArtifactsHttpAdapter, deps}, port: 0, startup_log: false)

    on_exit(fn -> stop_server(server) end)

    port = bound_port!(server)

    token =
      TokenIssuer.mint(@signing_key, "runner-1", "job-a", System.system_time(:second) + 3600).token

    %{
      base_url: "http://127.0.0.1:#{port}",
      token: token,
      run: "run-#{System.unique_integer([:positive])}"
    }
  end

  defp bound_port!(server) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
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

  # -- HTTP client helpers ----------------------------------------------------

  defp auth_header(token), do: [{"authorization", "Bearer " <> token}]

  defp create_artifact!(base_url, token, run, name, declared_size) do
    resp =
      Req.post!(base_url <> "/runs/#{run}/artifacts",
        json: %{"name" => name, "declaredSize" => declared_size},
        headers: auth_header(token),
        retry: false
      )

    {resp.status, resp.body}
  end

  defp upload_part!(base_url, token, run, upload_ref, index, content) do
    resp =
      Req.post!(base_url <> "/runs/#{run}/artifacts/parts",
        json: %{
          "uploadRef" => upload_ref,
          "partIndex" => index,
          "content" => Base.encode64(content)
        },
        headers: auth_header(token),
        retry: false
      )

    {resp.status, resp.body}
  end

  defp finalize!(base_url, token, run, upload_ref, declared_digest) do
    resp =
      Req.post!(base_url <> "/runs/#{run}/artifacts/finalize",
        json: %{"uploadRef" => upload_ref, "declaredDigest" => declared_digest},
        headers: auth_header(token),
        retry: false
      )

    {resp.status, resp.body}
  end

  defp list_artifacts!(base_url, token, run) do
    resp =
      Req.get!(base_url <> "/runs/#{run}/artifacts", headers: auth_header(token), retry: false)

    {resp.status, resp.body}
  end

  defp download!(base_url, token, run, name) do
    resp =
      Req.get!(base_url <> "/runs/#{run}/artifacts/#{name}",
        headers: auth_header(token),
        retry: false
      )

    {resp.status, resp.body}
  end

  # -- the round trip ----------------------------------------------------------

  test "full HTTP round-trip with out-of-order and duplicated parts; wrong-digest finalize is rejected",
       %{base_url: base_url, token: token, run: run} do
    parts = ["alpha-", "bravo-", "charlie-", "delta-", "echo-tail"]
    full_content = IO.iodata_to_binary(parts)
    declared_size = byte_size(full_content)
    declared_digest = Base.encode16(:crypto.hash(:sha256, full_content), case: :lower)

    {201, %{"uploadRef" => upload_ref}} =
      create_artifact!(base_url, token, run, "build.tar", declared_size)

    # Nothing is visible yet — the upload was created but not a single
    # part has landed, let alone finalized.
    {200, %{"artifacts" => before_finalize}} = list_artifacts!(base_url, token, run)

    # Upload all 5 parts out of order, resending part 2 a second time
    # (simulating a runner retrying after a reconnect) — idempotency
    # means the resend must change nothing about the assembled content.
    for index <- [2, 0, 4, 1, 2, 3] do
      assert {200, %{"status" => "ok"}} =
               upload_part!(base_url, token, run, upload_ref, index, Enum.at(parts, index))
    end

    {200, finalized} = finalize!(base_url, token, run, upload_ref, declared_digest)
    assert finalized["digest"] == declared_digest
    assert finalized["sizeBytes"] == declared_size

    {200, %{"artifacts" => after_finalize}} = list_artifacts!(base_url, token, run)
    assert length(after_finalize) == 1
    assert hd(after_finalize)["name"] == "build.tar"

    {200, downloaded} = download!(base_url, token, run, "build.tar")
    digest_match = downloaded == full_content

    # Second artifact: finalize with a WRONG digest (same declared size,
    # so only the digest check can fail) must be rejected and the
    # artifact must never become visible via list or read.
    bad_content = "totally-different-bytes"
    bad_declared_size = byte_size(bad_content)
    wrong_digest = String.duplicate("0", 64)

    {201, %{"uploadRef" => bad_upload_ref}} =
      create_artifact!(base_url, token, run, "bad.tar", bad_declared_size)

    assert {200, %{"status" => "ok"}} =
             upload_part!(base_url, token, run, bad_upload_ref, 0, bad_content)

    assert {409, %{"error" => "digest_mismatch"}} =
             finalize!(base_url, token, run, bad_upload_ref, wrong_digest)

    {200, %{"artifacts" => final_list}} = list_artifacts!(base_url, token, run)
    bad_digest_visible_count = Enum.count(final_list, &(&1["name"] == "bad.tar"))

    {bad_read_status, _body} = download!(base_url, token, run, "bad.tar")
    assert bad_read_status == 404

    visible_before_finalize = length(before_finalize)

    IO.puts(
      "artifacts_bytes=#{declared_size} digest_match=#{digest_match} " <>
        "visible_before_finalize=#{visible_before_finalize} bad_digest_visible=#{bad_digest_visible_count}"
    )

    assert digest_match == true
    assert visible_before_finalize == 0
    assert bad_digest_visible_count == 0
  end

  test "requests without a valid bearer token are rejected before touching the store", %{
    base_url: base_url,
    run: run
  } do
    resp =
      Req.post!(base_url <> "/runs/#{run}/artifacts",
        json: %{"name" => "x", "declaredSize" => 0},
        retry: false
      )

    assert resp.status == 401

    resp =
      Req.post!(base_url <> "/runs/#{run}/artifacts",
        json: %{"name" => "x", "declaredSize" => 0},
        headers: [{"authorization", "Bearer garbage"}],
        retry: false
      )

    assert resp.status == 401
  end
end
