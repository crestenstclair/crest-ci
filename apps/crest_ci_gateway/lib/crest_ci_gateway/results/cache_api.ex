defmodule CrestCiGateway.Results.CacheApi do
  @moduledoc """
  Application Service: `applicationService.Results.CacheApi` — the
  runner-facing HTTP surface for the cache flow (reserve, upload, commit,
  lookup).

  Endpoints, all under `/cache`:

    * `POST /cache/reserve` — `{"key", "version", "scope"}` ->
      `201 {"uploadRef", ...}` | `409 {"error": "already_committed"}`
    * `POST /cache/upload`  — `{"uploadRef", "offset", "content" (base64)}`
      -> `200 {"status": "ok"}`, idempotent by `(uploadRef, offset)`
    * `POST /cache/commit`  — `{"uploadRef", "declaredSize"}` ->
      `200 {"entry", ...}` | `422 {"error": "size_mismatch"}`
    * `POST /cache/lookup`  — `{"key", "restoreKeys", "scopeChain"}` ->
      `200 {"entry", "content" (base64)}` on a hit, or
      `200 {"status": "miss"}` on a miss

  A cache miss is **always** a well-formed `200` response, never an error
  status — a job's cache-restore step must never fail merely because
  nothing was cached yet. This mirrors the port's own contract
  (`port.Results.CacheStore.lookup/4` returns `:miss`, not an error tuple)
  and the project's runner-facing invariant that soft misses never fail a
  job.

  Every route is guarded by a job-scoped `RunnerToken` bearer check,
  verified *before* any collaborator (the `CacheStore`) is touched — an
  unauthenticated or expired request never causes a store access, matching
  the same ordering `CrestCiGateway.GatewayHttpServer` uses for its
  job-scoped routes. Cache routes are not job-path-scoped (there is no
  `:name` segment to cross-check), so any bearer token that verifies
  successfully — signature intact, not expired — authorizes the request;
  see the moduledoc on `CrestCiGateway.TokenIssuer` for why any gateway
  replica can make that call unassisted, with no session-store lookup.

  This module depends only on the `port.Results.CacheStore` abstraction
  (Dependency Inversion) — it never calls
  `CrestCiGateway.Results.RestoreKeyResolver` directly. Match selection for
  `lookup/4` is already delegated to `RestoreKeyResolver` *inside* the
  `CacheStore` port's contract (see `CrestCiGateway.Results.CacheStore` and
  `CrestCiGateway.Results.LocalFsCacheStore`), so re-calling it here would
  duplicate a decision that belongs to the store adapter and would also
  require this module to reach past the port into adapter-internal
  candidate-gathering. Token minting/verification is injected as a plain
  function on `Deps`, mirroring `CrestCiGateway.RunnerProtocolHttp.Deps` —
  this module is never coupled to a hard-coded `CrestCiGateway.TokenIssuer`
  call, so tests can substitute stub verification with zero coupling to
  the real HMAC implementation.

  `store` is held opaquely: a `reservation` returned by `CacheStore.reserve/4`
  is `term()` per the port's contract, so this module never assumes it is
  any particular shape (e.g. a map or a specific adapter's struct). The
  `uploadRef` wire token is produced by serializing that opaque term
  directly (`:erlang.term_to_binary/1`, base64url-encoded) and reversing it
  with `:erlang.binary_to_term/2` in `:safe` mode on the way back in — the
  same technique `CrestCiGateway.TokenIssuer` uses for its signed payload,
  chosen so this module never has to know (or assume) which concrete
  `CacheStore` adapter minted the reservation. Gateway replica-local state
  is otherwise nonexistent here: nothing about a reservation lives in this
  module's memory between requests, so a runner reconnecting to a
  different replica mid-upload is indistinguishable from staying on the
  same one.
  """

  @behaviour Plug

  alias CrestCiGateway.Results.CacheEntry
  alias CrestCiGateway.Results.CacheScope
  alias CrestCiGateway.Results.CacheStore

  defmodule Deps do
    @moduledoc """
    Everything `CrestCiGateway.Results.CacheApi` needs, injected by the
    assembler that boots a gateway replica. `store` is the opaque
    `port.Results.CacheStore`-conforming struct to dispatch through;
    `verify_token` is a plain function value (not a hard-coded module
    call) so tests can substitute stub verification, matching the
    Dependency Inversion already used by
    `CrestCiGateway.RunnerProtocolHttp.Deps`.
    """

    @enforce_keys [:store, :signing_key, :verify_token]
    defstruct [:store, :signing_key, :verify_token]

    @type claims :: %{
            optional(:runner_name) => String.t(),
            optional(:job_name) => String.t(),
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
      {:ok, _claims} ->
        dispatch(conn.method, conn.path_info, conn, deps)

      {:error, _reason} ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  @doc """
  Boot the cache HTTP surface bound to `port`, dispatching every request
  through `deps`. Returns `{:ok, server}`.
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

  # -- Routing -----------------------------------------------------------

  defp dispatch("POST", ["cache", "reserve"], conn, deps), do: handle_reserve(conn, deps)
  defp dispatch("POST", ["cache", "upload"], conn, deps), do: handle_upload(conn, deps)
  defp dispatch("POST", ["cache", "commit"], conn, deps), do: handle_commit(conn, deps)
  defp dispatch("POST", ["cache", "lookup"], conn, deps), do: handle_lookup(conn, deps)

  defp dispatch(method, path_info, conn, _deps) do
    send_json(conn, 500, %{
      "error" => "unknown_route",
      "method" => method,
      "path" => "/" <> Enum.join(path_info, "/")
    })
  end

  # -- POST /cache/reserve -------------------------------------------------

  defp handle_reserve(conn, deps) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, key} <- fetch_binary(body, "key"),
         {:ok, version} <- fetch_binary(body, "version"),
         {:ok, scope} <- CacheScope.from_wire(Map.get(body, "scope")) do
      case CacheStore.reserve(deps.store, key, version, scope) do
        {:ok, reservation} ->
          send_json(conn, 201, %{"uploadRef" => encode_ref(reservation)})

        {:error, :already_committed} ->
          send_json(conn, 409, %{"error" => "already_committed"})
      end
    else
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- POST /cache/upload ---------------------------------------------------

  defp handle_upload(conn, deps) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, reservation} <- decode_ref(Map.get(body, "uploadRef")),
         {:ok, offset} <- fetch_non_neg_integer(body, "offset"),
         {:ok, raw_content} <- fetch_binary(body, "content"),
         {:ok, content} <- Base.decode64(raw_content) do
      :ok = CacheStore.upload(deps.store, reservation, offset, content)
      send_json(conn, 200, %{"status" => "ok"})
    else
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- POST /cache/commit ---------------------------------------------------

  defp handle_commit(conn, deps) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, reservation} <- decode_ref(Map.get(body, "uploadRef")),
         {:ok, declared_size} <- fetch_non_neg_integer(body, "declaredSize") do
      case CacheStore.commit(deps.store, reservation, declared_size) do
        {:ok, entry} -> send_json(conn, 200, %{"entry" => CacheEntry.to_wire(entry)})
        {:error, :size_mismatch} -> send_json(conn, 422, %{"error" => "size_mismatch"})
      end
    else
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- POST /cache/lookup ---------------------------------------------------

  defp handle_lookup(conn, deps) do
    with {:ok, body, conn} <- read_json_body(conn),
         {:ok, key} <- fetch_binary(body, "key"),
         {:ok, restore_keys} <- fetch_string_list(body, "restoreKeys"),
         {:ok, scope_chain} <- parse_scope_chain(Map.get(body, "scopeChain")) do
      case CacheStore.lookup(deps.store, key, restore_keys, scope_chain) do
        {:ok, entry, content} ->
          send_json(conn, 200, %{
            "entry" => CacheEntry.to_wire(entry),
            "content" => Base.encode64(content)
          })

        :miss ->
          # A cache miss is a normal, well-formed response — never an
          # error status that would fail the runner's cache-restore step.
          send_json(conn, 200, %{"status" => "miss"})
      end
    else
      _malformed -> send_json(conn, 400, %{"error" => "malformed_body"})
    end
  end

  # -- Auth helpers --------------------------------------------------------

  # Verifies the bearer token BEFORE any collaborator is invoked — an
  # expired or tampered token never triggers a `CacheStore` access.
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

  # -- Opaque reservation <-> uploadRef -------------------------------------

  # `reservation` is `term()` per `port.Results.CacheStore` — this module
  # never assumes any particular shape (map, struct, tuple, ...). Encoding
  # the raw term is what lets any conforming `CacheStore` adapter's
  # reservation round-trip through this HTTP boundary untouched.
  defp encode_ref(reservation) do
    reservation |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  end

  # `:safe` mode never creates atoms or reconstructs funs/pids from the
  # decoded bytes — an invalid or tampered `uploadRef` fails closed with
  # `{:error, :invalid_upload_ref}` rather than admitting arbitrary terms,
  # the same discipline `CrestCiGateway.TokenIssuer.verify/2` applies to
  # its own opaque wire payload.
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

  defp fetch_string_list(body, key) when is_map(body) do
    case Map.get(body, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error

      _other ->
        :error
    end
  end

  defp parse_scope_chain(wire_list) when is_list(wire_list) do
    Enum.reduce_while(wire_list, {:ok, []}, fn wire, {:ok, acc} ->
      case CacheScope.from_wire(wire) do
        {:ok, scope} -> {:cont, {:ok, [scope | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, scopes} -> {:ok, Enum.reverse(scopes)}
      :error -> :error
    end
  end

  defp parse_scope_chain(_other), do: :error

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
