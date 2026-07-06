defmodule CrestCiGateway.GatewayHttpServerTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias CrestCiGateway.RunnerProtocolHttp.Deps
  alias CrestCiGateway.GatewayHttpServer

  @signing_key "test-signing-key"

  defp base_deps(overrides \\ %{}) do
    defaults = %{
      kube_conn: :fake_conn,
      signing_key: @signing_key,
      authenticate_jit: fn body ->
        if body["jit_config"] == "valid" do
          {:ok, %{runner_name: body["runner_name"], job_name: body["job_name"]}}
        else
          {:error, :invalid}
        end
      end,
      mint_token: fn _key, runner_name, job_name, exp ->
        Jason.encode!(%{"r" => runner_name, "j" => job_name, "exp" => exp})
      end,
      verify_token: fn _key, token ->
        case Jason.decode(token) do
          {:ok, %{"r" => r, "j" => j, "exp" => exp}} ->
            if exp < System.system_time(:second) do
              {:error, :expired}
            else
              {:ok, %{runner_name: r, job_name: j, exp: exp}}
            end

          _ ->
            {:error, :invalid}
        end
      end,
      lease: fn _conn, _name, _by, _dur -> {:ok, :leased} end,
      confirm_acquisition: fn _conn, _name, _by -> {:ok, :acquired} end,
      poll: fn _deps, _labels, _deadline -> :timeout end,
      ingest_chunk: fn _deps, _job, _step, _seq, _content -> :ok end,
      project_status: fn _conn, _wr, _jk, _progress -> {:ok, %{}} end,
      long_poll_deadline_ms: 50
    }

    struct!(Deps, Map.merge(defaults, overrides))
  end

  defp valid_token(deps, runner_name \\ "runner-1", job_name \\ "job-a", ttl_seconds \\ 3600) do
    deps.mint_token.(
      deps.signing_key,
      runner_name,
      job_name,
      System.system_time(:second) + ttl_seconds
    )
  end

  defp with_bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  # -- unknown routes ---------------------------------------------------------

  test "unknown route returns 500" do
    deps = base_deps()
    resp = conn(:get, "/totally/unknown") |> GatewayHttpServer.call(deps)
    assert resp.status == 500
  end

  test "unknown method on a known path returns 500" do
    deps = base_deps()
    resp = conn(:delete, "/session") |> GatewayHttpServer.call(deps)
    assert resp.status == 500
  end

  # -- POST /session ------------------------------------------------------------

  test "POST /session with valid JIT config mints a token (201)" do
    deps = base_deps()

    resp =
      conn(
        :post,
        "/session",
        Jason.encode!(%{"runner_name" => "r1", "job_name" => "job-a", "jit_config" => "valid"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> GatewayHttpServer.call(deps)

    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)
    assert is_binary(body["token"])
  end

  test "POST /session with invalid JIT config is rejected (401)" do
    deps = base_deps()

    resp =
      conn(
        :post,
        "/session",
        Jason.encode!(%{"runner_name" => "r1", "job_name" => "job-a", "jit_config" => "bogus"})
      )
      |> GatewayHttpServer.call(deps)

    assert resp.status == 401
  end

  # -- GET /session/messages (long-poll) -----------------------------------

  test "GET /session/messages returns 204 when the poll times out with no job" do
    deps = base_deps(%{poll: fn _deps, _labels, _deadline -> :timeout end})
    token = valid_token(deps)

    resp =
      conn(:get, "/session/messages")
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 204
  end

  test "GET /session/messages returns 200 with the job message when one becomes available" do
    deps = base_deps(%{poll: fn _deps, _labels, _deadline -> {:ok, %{"job_key" => "build"}} end})
    token = valid_token(deps)

    resp =
      conn(:get, "/session/messages")
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body) == %{"job_key" => "build"}
  end

  test "GET /session/messages rejects a missing token with 401 and never polls" do
    test_pid = self()

    deps =
      base_deps(%{poll: fn _deps, _labels, _deadline -> send(test_pid, :polled) && :timeout end})

    resp = conn(:get, "/session/messages") |> GatewayHttpServer.call(deps)

    assert resp.status == 401
    refute_received :polled
  end

  # -- token rejection happens before any collaborator is touched ------------

  test "expired token is rejected with 401 before any collaborator is called" do
    test_pid = self()

    deps =
      base_deps(%{
        confirm_acquisition: fn _conn, _name, _by ->
          send(test_pid, :store_touched)
          {:ok, :acquired}
        end
      })

    expired = deps.mint_token.(deps.signing_key, "r1", "job-a", System.system_time(:second) - 10)

    resp =
      conn(:post, "/jobs/job-a/ack", "")
      |> with_bearer(expired)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 401
    refute_received :store_touched
  end

  test "tampered token is rejected with 401 before any collaborator is called" do
    test_pid = self()

    deps =
      base_deps(%{
        confirm_acquisition: fn _conn, _name, _by ->
          send(test_pid, :store_touched)
          {:ok, :acquired}
        end
      })

    resp =
      conn(:post, "/jobs/job-a/ack", "")
      |> with_bearer("not-a-real-token")
      |> GatewayHttpServer.call(deps)

    assert resp.status == 401
    refute_received :store_touched
  end

  test "a missing Authorization header is rejected with 401" do
    deps = base_deps()
    resp = conn(:post, "/jobs/job-a/ack", "") |> GatewayHttpServer.call(deps)
    assert resp.status == 401
  end

  # -- cross-job rejection ---------------------------------------------------

  test "job-scoped route rejects a valid token whose job does not match the path" do
    deps = base_deps()
    token = valid_token(deps, "runner-1", "job-a")

    resp =
      conn(:post, "/jobs/job-b/ack", "")
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 401
  end

  test "job-scoped route accepts a valid token whose job matches the path" do
    deps = base_deps()
    token = valid_token(deps, "runner-1", "job-a")

    resp =
      conn(:post, "/jobs/job-a/ack", "")
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200
  end

  # -- ack / logs / timeline / complete happy paths --------------------------

  test "POST /jobs/:name/ack confirms acquisition with the token's runner and the path's job" do
    test_pid = self()

    deps =
      base_deps(%{
        confirm_acquisition: fn _conn, job_name, runner_name ->
          send(test_pid, {:confirmed, job_name, runner_name})
          {:ok, :acquired}
        end
      })

    token = valid_token(deps, "runner-1", "job-a")

    resp =
      conn(:post, "/jobs/job-a/ack", "") |> with_bearer(token) |> GatewayHttpServer.call(deps)

    assert resp.status == 200
    assert_received {:confirmed, "job-a", "runner-1"}
  end

  test "POST /jobs/:name/ack returns 409 when the lease was already lost" do
    deps = base_deps(%{confirm_acquisition: fn _conn, _name, _by -> {:error, :lost} end})
    token = valid_token(deps)

    resp =
      conn(:post, "/jobs/job-a/ack", "") |> with_bearer(token) |> GatewayHttpServer.call(deps)

    assert resp.status == 409
  end

  test "POST /jobs/:name/logs forwards the chunk to ingest_chunk" do
    test_pid = self()

    deps =
      base_deps(%{
        ingest_chunk: fn _deps, job_name, step, seq, content ->
          send(test_pid, {:ingested, job_name, step, seq, content})
          :ok
        end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/logs",
        Jason.encode!(%{"step" => "build", "seq" => 1, "content" => "hello"})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200
    assert_received {:ingested, "job-a", "build", 1, "hello"}
  end

  test "POST /jobs/:name/logs surfaces an ingest error as 500" do
    deps =
      base_deps(%{
        ingest_chunk: fn _deps, _job, _step, _seq, _content -> {:error, :disk_full} end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/logs",
        Jason.encode!(%{"step" => "build", "seq" => 1, "content" => "hi"})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 500
  end

  test "POST /jobs/:name/timeline projects step status" do
    test_pid = self()

    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, progress ->
          send(test_pid, {:projected, progress})
          {:ok, %{}}
        end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/timeline",
        Jason.encode!(%{"step" => "build", "status" => "running"})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200

    assert_received {:projected,
                     %{"kind" => "timeline", "step" => "build", "status" => "running"}}
  end

  test "POST /jobs/:name/complete projects the result and outputs" do
    test_pid = self()

    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, progress ->
          send(test_pid, {:projected, progress})
          {:ok, %{}}
        end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "success", "outputs" => %{"x" => "1"}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200

    assert_received {:projected,
                     %{"kind" => "complete", "result" => "success", "outputs" => %{"x" => "1"}}}
  end

  test "POST /jobs/:name/complete surfaces a projection failure as 500" do
    deps = base_deps(%{project_status: fn _conn, _wr, _jk, _progress -> {:error, :conflict} end})
    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "failed", "outputs" => %{}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 500
  end

  # -- POST /jobs/:name/complete -> applicationService.Results.ArchiveOnComplete ---
  #
  # `archive_on_complete` is the gateway's job-completion hook for log
  # archiving: `base_deps/1` leaves it `nil` (never configured), which is
  # exactly what every test above this section exercises -- completion
  # succeeds with no archiving collaborator touched at all. These tests
  # cover the opt-in path.

  test "POST /jobs/:name/complete with no archive_on_complete configured still succeeds (200)" do
    deps = base_deps()
    refute deps.archive_on_complete
    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "success", "outputs" => %{}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200
  end

  test "POST /jobs/:name/complete runs archive_on_complete only AFTER a successful projection, with the completion's workflow_run/job_key" do
    test_pid = self()

    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, _progress -> {:ok, %{}} end,
        archive_on_complete: fn conn, workflow_run, job_key ->
          send(test_pid, {:archived, conn, workflow_run, job_key})
          {:ok, %{}}
        end
      })

    token = valid_token(deps, "runner-1", "job-a")

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "success", "outputs" => %{}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 200
    assert_received {:archived, :fake_conn, "job-a", "job-a"}
  end

  test "POST /jobs/:name/complete never runs archive_on_complete when the projection fails" do
    test_pid = self()

    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, _progress -> {:error, :conflict} end,
        archive_on_complete: fn _conn, _wr, _jk ->
          send(test_pid, :archive_touched)
          {:ok, %{}}
        end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "failed", "outputs" => %{}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 500
    refute_received :archive_touched
  end

  test "POST /jobs/:name/complete surfaces an archive_on_complete failure as 500 (retry-safe: projection already succeeded and is itself idempotent)" do
    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, _progress -> {:ok, %{}} end,
        archive_on_complete: fn _conn, _wr, _jk -> {:error, :disk_full} end
      })

    token = valid_token(deps)

    resp =
      conn(
        :post,
        "/jobs/job-a/complete",
        Jason.encode!(%{"result" => "success", "outputs" => %{}})
      )
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp.status == 500
  end

  test "POST /jobs/:name/complete calling archive_on_complete twice for the same job is safe (idempotent hook)" do
    test_pid = self()

    deps =
      base_deps(%{
        project_status: fn _conn, _wr, _jk, _progress -> {:ok, %{}} end,
        archive_on_complete: fn _conn, _wr, _jk ->
          send(test_pid, :archived_again)
          {:ok, %{}}
        end
      })

    token = valid_token(deps, "runner-1", "job-a")
    body = Jason.encode!(%{"result" => "success", "outputs" => %{}})

    resp1 =
      conn(:post, "/jobs/job-a/complete", body)
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    resp2 =
      conn(:post, "/jobs/job-a/complete", body)
      |> with_bearer(token)
      |> GatewayHttpServer.call(deps)

    assert resp1.status == 200
    assert resp2.status == 200
    assert_received :archived_again
    assert_received :archived_again
  end

  # -- real end-to-end over a bound socket -----------------------------------

  describe "serve/2 over a real socket" do
    setup do
      deps = base_deps()
      {:ok, server} = GatewayHttpServer.serve(deps, 0)
      {:ok, port} = GatewayHttpServer.bound_port(server)
      on_exit(fn -> Process.exit(server, :normal) end)
      %{deps: deps, port: port}
    end

    test "boots and answers a real HTTP request", %{deps: deps, port: port} do
      base = "http://127.0.0.1:#{port}"

      resp =
        Req.post!(base <> "/session",
          json: %{"runner_name" => "r1", "job_name" => "job-a", "jit_config" => "valid"},
          retry: false
        )

      assert resp.status == 201
      token = resp.body["token"]
      assert is_binary(token)

      resp =
        Req.get!(base <> "/session/messages",
          headers: [{"authorization", "Bearer " <> token}],
          retry: false
        )

      assert resp.status == 204

      resp = Req.get!(base <> "/does-not-exist", retry: false)
      assert resp.status == 500

      _ = deps
    end
  end
end
