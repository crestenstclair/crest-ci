defmodule CrestCiGateway.Results.ArtifactsApi do
  @moduledoc """
  Application Service: `applicationService.Results.ArtifactsApi` — the
  runner-facing HTTP surface for the artifacts flow: create -> upload
  parts -> finalize; list + download.

  Endpoints, all job-scoped under `/jobs/:job/artifacts`:

    * `POST /jobs/:job/artifacts`           — `{"name", "declaredSize"}` ->
      `201 {"uploadRef", ...}` | `409 {"error": "already_exists"}`
    * `POST /jobs/:job/artifacts/parts`     — `{"uploadRef", "partIndex",
      "content" (base64)}` -> `200 {"status": "ok"}`, idempotent by
      `(uploadRef, partIndex)`
    * `POST /jobs/:job/artifacts/finalize`  — `{"uploadRef", "declaredDigest"}`
      -> `200 <ArtifactRecord wire>` | `409 {"error": "digest_mismatch" |
      "size_mismatch"}`
    * `GET  /jobs/:job/artifacts`           — `200 {"artifacts": [...]}`,
      finalized artifacts only
    * `GET  /jobs/:job/artifacts/:name`     — `200 <raw bytes>` | `404`

  Every route authenticates the bearer `RunnerToken` FIRST — before any
  collaborator (`port.Results.ArtifactStore`) is touched — mirroring the
  ordering `CrestCiGateway.GatewayHttpServer` uses for its own job-scoped
  routes. Unlike `CrestCiGateway.Results.CacheApi` (whose routes are not
  job-path-scoped), every route here also has a `:job` path segment that
  MUST match the token's own `job_name`; a valid token for a *different*
  job is rejected with `401 job_mismatch` before `ArtifactStore` is ever
  reached — this is what "confined to that job's run" means operationally.

  This module has no Kubernetes API access and no dependency on any
  run-to-job mapping — the only collaborators it declares are
  `port.Results.ArtifactStore` and `domainService.Gateway.TokenIssuer`
  (the latter only via the injected `verify_token` function on `Deps`,
  never called through a hard-coded module reference). Consequently every
  handler here uses the authenticated `job_name` as BOTH the `job` and the
  `run` scope handed to `ArtifactStore` — there is no client-suppliable
  override for either, so a runner can never widen its own scope by
  supplying a different run identifier: none is ever accepted from the
  request. "Confined to that job's run" is therefore enforced by
  construction, not by a runtime check a client input could bypass.

  `store` is held opaquely (Dependency Inversion — this module depends on
  the `ArtifactStore` port's abstraction, never on a concrete adapter such
  as `CrestCiGateway.Results.LocalFsArtifactStore`). `upload_ref` is
  likewise `term()` per the port's contract; it is round-tripped through
  the HTTP boundary the same way `CacheApi` round-trips its opaque
  `reservation` — raw `:erlang.term_to_binary/1`, base64url-encoded on the
  way out, decoded with `:erlang.binary_to_term/2` in `:safe` mode on the
  way back in, so this module never has to assume any particular
  `ArtifactStore` adapter's `upload_ref` shape, and a tampered `uploadRef`
  fails closed rather than admitting arbitrary terms.
  """

  @behaviour Plug

  alias CrestCiGateway.Results.ArtifactName
  alias CrestCiGateway.Results.ArtifactRecord
  alias CrestCiGateway.Results.ArtifactStore

  defmodule Deps do
    @moduledoc """
    Everything `CrestCiGateway.Results.ArtifactsApi` needs, injected by the
    assembler that boots a gateway replica. `store` is the opaque
    `port.Results.ArtifactStore`-conforming struct to dispatch through;
    `verify_token` is a plain function value (not a hard-coded module
    call) so tests can substitute stub verification, matching the
    Dependency Inversion already used by
    `CrestCiGateway.RunnerProtocolHttp.Deps` and
    `CrestCiGateway.Results.CacheApi.Deps`.
    """

    @enforce_keys [:store, :signing_key, :verify_token]
    defstruct [:store, :signing_key, :verify_token]

    @type claims :: %{
            optional(:runner_name) => String.t(),
            required(:job_name) => String.t(),
            optional(:expires_at) => integer()
          }

    @type t :: %__MODULE__{
            store: struct(),
            signing_key: binary(),
            verify_token: (binary(), String.t() -> {:ok, claims()} | {:error, term()})
          }
  end

  @impl Plug
  def init(%Deps{} = deps), do: deps

  @impl Plug
  def call(conn, %Deps{} = deps) do
    conn = Plug.Conn.fetch_query_params(conn)

    case authenticate_bearer(conn, deps) do
      {:ok, claims} -> dispatch(conn.method, conn.path_info, conn, deps, claims)
      {:error, _reason} -> send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  @doc """
  Boot the artifacts HTTP surface bound to `port`, dispatching every
  request through `deps`. Returns `{:ok, server}`.
  """
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

  # -- Routing: job-path match is enforced on every clause before any handler runs --

  defp dispatch("POST", ["jobs", job, "artifacts"], conn, deps, claims),
    do: with_job_auth(conn, claims, job, &handle_create(conn, deps, &1))

  defp dispatch("POST", ["jobs", job, "artifacts", "parts"], conn, deps, claims),
    do: with_job_auth(conn, claims, job, &handle_upload_part(conn, deps, &1))

  defp dispatch("POST", ["jobs", job, "artifacts", "finalize"], conn, deps, claims),
    do: with_job_auth(conn, claims, job, &handle_finalize(conn, deps, &1))

  defp dispatch("GET", ["jobs", job, "artifacts"], conn, deps, claims),
    do: with_job_auth(conn, claims, job, &handle_list(conn, deps, &1))

  defp dispatch("GET", ["jobs", job, "artifacts", name], conn, deps, claims),
    do: with_job_auth(conn, claims, job, &handle_read(conn, deps, &1, name))

  defp dispatch(method, path_info, conn, _deps, _claims) do
    send_json(conn, 500, %{
      "error" => "unknown_route",
      "method" => method,
      "path" => "/" <> Enum.join(path_info, "/")
    })
  end

  # A valid token for a DIFFERENT job than the one in the path is rejected
  # before `handler` (and therefore `ArtifactStore`) ever runs — this is
  # the one enforcement point for "confined to that job's run".
  defp with_job_auth(_conn, %{job_name: path_job} = claims, path_job, handler),
    do: handler.(claims)

  defp with_job_auth(conn, %{job_name: _other}, _path_job, _handler),
    do: send_json(conn, 401, %{"error" => "job_mismatch"})

  # -- POST /jobs/:job/artifacts — begin an upload --------------------------

  defp handle_create(conn, deps, %{job_name: job_name}) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, name} <- fetch_binary(body, "name"),
         {:ok, declared_size} <- fetch_non_neg_integer(body, "declaredSize"),
         {:ok, valid_name} <- ArtifactName.new(name),
         {:ok, upload_ref} <-
           ArtifactStore.create(deps.store, job_name, job_name, valid_name, declared_size) do
      send_json(conn, 201, %{"uploadRef" => encode_ref(upload_ref)})
    else
      {:error, :already_exists} -> send_json(conn, 409, %{"error" => "already_exists"})
      {:error, :invalid_artifact_name} -> send_json(conn, 400, %{"error" => "invalid_name"})
      {:error, _reason} -> send_json(conn, 500, %{"error" => "create_failed"})
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- POST /jobs/:job/artifacts/parts — upload one part --------------------

  defp handle_upload_part(conn, deps, _claims) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, upload_ref} <- decode_ref(Map.get(body, "uploadRef")),
         {:ok, part_index} <- fetch_non_neg_integer(body, "partIndex"),
         {:ok, raw_content} <- fetch_binary(body, "content"),
         {:ok, content} <- Base.decode64(raw_content),
         :ok <- ArtifactStore.upload_part(deps.store, upload_ref, part_index, content) do
      send_json(conn, 200, %{"status" => "ok"})
    else
      # A garbage/tampered `uploadRef` is a client-input shape problem, not
      # a store failure — it must resolve as 400 malformed_body, the same
      # as any other unparsable field, never as a 500.
      {:error, :invalid_upload_ref} -> send_json(conn, 400, %{"error" => "malformed_body"})
      {:error, _reason} -> send_json(conn, 500, %{"error" => "upload_failed"})
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- POST /jobs/:job/artifacts/finalize — atomic commit point -------------

  defp handle_finalize(conn, deps, _claims) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, upload_ref} <- decode_ref(Map.get(body, "uploadRef")),
         {:ok, declared_digest} <- fetch_binary(body, "declaredDigest"),
         {:ok, record} <- ArtifactStore.finalize(deps.store, upload_ref, declared_digest) do
      send_json(conn, 200, ArtifactRecord.to_wire(record))
    else
      {:error, :invalid_upload_ref} -> send_json(conn, 400, %{"error" => "malformed_body"})
      {:error, :digest_mismatch} -> send_json(conn, 409, %{"error" => "digest_mismatch"})
      {:error, :size_mismatch} -> send_json(conn, 409, %{"error" => "size_mismatch"})
      {:error, _reason} -> send_json(conn, 500, %{"error" => "finalize_failed"})
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- GET /jobs/:job/artifacts — list finalized artifacts ------------------

  defp handle_list(conn, deps, %{job_name: job_name}) do
    {:ok, records} = ArtifactStore.list(deps.store, job_name)
    send_json(conn, 200, %{"artifacts" => Enum.map(records, &ArtifactRecord.to_wire/1)})
  end

  # -- GET /jobs/:job/artifacts/:name — download ----------------------------

  defp handle_read(conn, deps, %{job_name: job_name}, name) do
    case ArtifactName.new(name) do
      {:ok, valid_name} ->
        case ArtifactStore.read(deps.store, job_name, valid_name) do
          {:ok, content} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_resp(200, content)

          {:error, :not_found} ->
            send_json(conn, 404, %{"error" => "not_found"})
        end

      {:error, :invalid_artifact_name} ->
        send_json(conn, 400, %{"error" => "invalid_name"})
    end
  end

  # -- Auth helpers --------------------------------------------------------

  # Verifies the bearer token BEFORE any collaborator is invoked — an
  # expired or tampered token never triggers an `ArtifactStore` access.
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

  # -- Opaque upload_ref <-> uploadRef ---------------------------------------

  # `upload_ref` is `term()` per `port.Results.ArtifactStore` — this module
  # never assumes any particular shape. Encoding the raw term is what lets
  # any conforming `ArtifactStore` adapter's `upload_ref` round-trip through
  # this HTTP boundary untouched, exactly as `CacheApi` does for its own
  # opaque `reservation`.
  defp encode_ref(upload_ref) do
    upload_ref |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  end

  # `:safe` mode never creates atoms or reconstructs funs/pids from the
  # decoded bytes — an invalid or tampered `uploadRef` fails closed with
  # `{:error, :invalid_upload_ref}` rather than admitting arbitrary terms.
  defp decode_ref(token) when is_binary(token) do
    with {:ok, bin} <- Base.url_decode64(token, padding: false) do
      try do
        {:ok, :erlang.binary_to_term(bin, [:safe])}
      rescue
        ArgumentError -> {:error, :invalid_upload_ref}
      end
    else
      :error -> {:error, :invalid_upload_ref}
    end
  end

  defp decode_ref(_other), do: {:error, :invalid_upload_ref}

  # -- Body parsing helpers --------------------------------------------------

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", conn} -> {:ok, %{}, conn}
      {:ok, raw, conn} -> with {:ok, decoded} <- Jason.decode(raw), do: {:ok, decoded, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_binary(body, key) when is_map(body) do
    case Map.get(body, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_non_neg_integer(body, key) when is_map(body) do
    case Map.get(body, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
