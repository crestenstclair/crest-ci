defmodule CrestCiGateway.GatewayHttpServer do
  @moduledoc """
  Adapter: implements `port.Gateway.RunnerProtocolHttp` (`CrestCiGateway.RunnerProtocolHttp`)
  over Plug + Bandit.

  Endpoints v0:

    * `POST /session`               — JIT-config auth -> `RunnerToken`
    * `GET  /session/messages`      — long-poll (~30s deadline) -> job message or 204
    * `POST /jobs/:name/ack`        — confirm acquisition
    * `POST /jobs/:name/logs`       — chunk upload
    * `POST /jobs/:name/timeline`   — step status
    * `POST /jobs/:name/complete`   — result + outputs

  Every job-scoped route authenticates the bearer `RunnerToken` FIRST and
  rejects before touching any collaborator (store, lease arbiter, log
  ingest, ...) when the token is missing, expired, tampered, or scoped to a
  different job than the one in the path. Unknown routes return 500 and log
  loudly — a deliberate bring-up rule so a client hitting a route that does
  not exist yet fails loudly rather than silently 404ing.

  This module is a thin transport: it owns HTTP concerns only (method/path
  dispatch, header/body parsing, status codes). All behavior — leasing,
  token semantics, status projection, dispatch, log storage — is delegated
  to the functions injected on `deps` (a `CrestCiGateway.RunnerProtocolHttp.Deps`),
  never called through a hard-coded module name (Dependency Inversion).
  """

  @behaviour Plug
  @behaviour CrestCiGateway.RunnerProtocolHttp

  require Logger

  alias CrestCiGateway.RunnerProtocolHttp.Deps

  @impl Plug
  def init(%Deps{} = deps), do: deps

  @impl Plug
  def call(conn, %Deps{} = deps) do
    conn = Plug.Conn.fetch_query_params(conn)
    dispatch(conn.method, conn.path_info, conn, deps)
  end

  @impl CrestCiGateway.RunnerProtocolHttp
  @spec serve(Deps.t(), :inet.port_number()) :: {:ok, pid()} | {:error, term()}
  def serve(%Deps{} = deps, port) when is_integer(port) and port >= 0 do
    Bandit.start_link(plug: {__MODULE__, deps}, port: port, startup_log: false)
  end

  @doc "The TCP port a running `serve/2` server is actually bound to (useful when `port: 0`)."
  @spec bound_port(pid()) :: {:ok, :inet.port_number()} | {:error, term()}
  def bound_port(server) when is_pid(server) do
    case ThousandIsland.listener_info(server) do
      {:ok, {_address, port}} -> {:ok, port}
      other -> {:error, other}
    end
  end

  # -- Routing ---------------------------------------------------------------

  defp dispatch("POST", ["session"], conn, deps), do: handle_create_session(conn, deps)
  defp dispatch("GET", ["session", "messages"], conn, deps), do: handle_long_poll(conn, deps)

  defp dispatch("POST", ["jobs", name, "ack"], conn, deps),
    do: with_job_auth(conn, deps, name, &handle_ack/3)

  defp dispatch("POST", ["jobs", name, "logs"], conn, deps),
    do: with_job_auth(conn, deps, name, &handle_logs/3)

  defp dispatch("POST", ["jobs", name, "timeline"], conn, deps),
    do: with_job_auth(conn, deps, name, &handle_timeline/3)

  defp dispatch("POST", ["jobs", name, "complete"], conn, deps),
    do: with_job_auth(conn, deps, name, &handle_complete/3)

  defp dispatch(method, path_info, conn, _deps) do
    Logger.error(
      "runner protocol: unmatched route #{method} /#{Enum.join(path_info, "/")} — returning 500 (bring-up rule: unknown routes never 404 silently)"
    )

    send_json(conn, 500, %{
      "error" => "unknown_route",
      "method" => method,
      "path" => "/" <> Enum.join(path_info, "/")
    })
  end

  # -- POST /session -----------------------------------------------------------

  defp handle_create_session(conn, deps) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, %{runner_name: runner_name, job_name: job_name}} <- deps.authenticate_jit.(body) do
      expiry = System.system_time(:second) + div(deps.token_ttl_ms || 3_600_000, 1000)
      token = deps.mint_token.(deps.signing_key, runner_name, job_name, expiry)

      send_json(conn, 201, %{
        "token" => token,
        "runner_name" => runner_name,
        "job_name" => job_name
      })
    else
      {:error, :invalid} -> send_json(conn, 401, %{"error" => "invalid_jit_config"})
      {:error, _} -> send_json(conn, 401, %{"error" => "invalid_jit_config"})
    end
  end

  # -- GET /session/messages ---------------------------------------------------

  defp handle_long_poll(conn, deps) do
    case authenticate_bearer(conn, deps) do
      {:ok, %{job_name: job_name}} ->
        case deps.poll.(deps, [job_name], deps.long_poll_deadline_ms) do
          {:ok, job_message} -> send_json(conn, 200, job_message_to_map(job_message))
          :timeout -> Plug.Conn.send_resp(conn, 204, "")
        end

      {:error, _reason} ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  # -- job-scoped routes: authenticate + enforce job match before ANY other work --

  defp with_job_auth(conn, deps, path_job_name, handler) do
    case authenticate_bearer(conn, deps) do
      {:ok, %{job_name: ^path_job_name} = claims} ->
        handler.(conn, deps, claims)

      {:ok, %{job_name: _other}} ->
        # valid token, wrong job — cross-job access is always rejected, no
        # store access is made on behalf of the mismatched job.
        send_json(conn, 401, %{"error" => "job_mismatch"})

      {:error, _reason} ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  defp handle_ack(conn, deps, %{runner_name: runner_name, job_name: job_name}) do
    case deps.confirm_acquisition.(deps.kube_conn, job_name, runner_name) do
      {:ok, :acquired} -> send_json(conn, 200, %{"status" => "acquired"})
      {:error, :lost} -> send_json(conn, 409, %{"error" => "lost"})
      {:error, _reason} -> send_json(conn, 500, %{"error" => "ack_failed"})
    end
  end

  defp handle_logs(conn, deps, %{job_name: job_name}) do
    with {:ok, body, conn} <- read_json_body(conn),
         %{"step" => step, "seq" => seq, "content" => content} <- body,
         :ok <- deps.ingest_chunk.(deps, job_name, step, seq, content) do
      send_json(conn, 200, %{"status" => "ok"})
    else
      {:error, _reason} -> send_json(conn, 500, %{"error" => "ingest_failed"})
      _malformed -> send_json(conn, 400, %{"error" => "malformed_chunk"})
    end
  end

  defp handle_timeline(conn, deps, %{job_name: job_name}) do
    with {:ok, body, conn} <- read_json_body(conn) do
      workflow_run = Map.get(body, "workflow_run", job_name)
      job_key = Map.get(body, "job_key", job_name)
      progress = %{"kind" => "timeline", "step" => body["step"], "status" => body["status"]}

      case deps.project_status.(deps.kube_conn, workflow_run, job_key, progress) do
        {:ok, _object} -> send_json(conn, 200, %{"status" => "ok"})
        {:error, _reason} -> send_json(conn, 500, %{"error" => "projection_failed"})
      end
    else
      {:error, _reason} -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  defp handle_complete(conn, deps, %{job_name: job_name}) do
    with {:ok, body, conn} <- read_json_body(conn) do
      workflow_run = Map.get(body, "workflow_run", job_name)
      job_key = Map.get(body, "job_key", job_name)
      progress = %{"kind" => "complete", "result" => body["result"], "outputs" => body["outputs"]}

      case deps.project_status.(deps.kube_conn, workflow_run, job_key, progress) do
        {:ok, _object} -> send_json(conn, 200, %{"status" => "ok"})
        {:error, _reason} -> send_json(conn, 500, %{"error" => "projection_failed"})
      end
    else
      {:error, _reason} -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- Auth helpers --------------------------------------------------------

  # Verifies the bearer token BEFORE any collaborator is invoked — expired
  # or tampered tokens never trigger a store access (LeaseArbiter,
  # StatusProjector, JobDispatcher, LogIngest are all untouched here).
  defp authenticate_bearer(conn, deps) do
    with [auth_header | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth_header,
         {:ok, claims} <- deps.verify_token.(deps.signing_key, token) do
      {:ok, claims}
    else
      [] -> {:error, :missing_token}
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :invalid}
    end
  end

  # -- Body / response helpers ---------------------------------------------

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, decoded, conn}
          {:error, _reason} -> {:error, :malformed_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp job_message_to_map(msg) when is_map(msg), do: msg
  defp job_message_to_map(msg), do: %{"job_message" => msg}

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
