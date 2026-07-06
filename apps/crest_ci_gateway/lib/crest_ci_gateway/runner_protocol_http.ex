defmodule CrestCiGateway.RunnerProtocolHttp do
  @moduledoc """
  Port: the HTTP surface runners dial (long-poll job delivery, lease
  acquisition, log/timeline/completion reporting).

  `serve/2` is the only contract member: `(deps, port) -> {:ok, server}`.
  Everything the HTTP transport needs to do its job — lease arbitration,
  token minting/verification, status projection, job dispatch, log ingest —
  is accepted as injected functions on `#{inspect(__MODULE__)}.Deps`, never
  called through a hard-coded module name. This is Dependency Inversion at
  the port boundary: the HTTP adapter depends on function-shaped
  abstractions it is handed, not on concrete domain-service modules, so it
  compiles and is fully testable in isolation from however the rest of the
  Gateway bounded context (LeaseArbiter, TokenIssuer, StatusProjector,
  JobDispatcher, LogIngest, BlobStore, KubeClient) is wired together at
  boot.
  """

  defmodule Deps do
    @moduledoc """
    Everything `CrestCiGateway.GatewayHttpServer` needs, injected by the
    assembler that boots a gateway replica. Every collaborator is a plain
    function value (or opaque connection term) — no field aliases a
    concrete module, so a test can supply stub functions with zero coupling
    to real implementations.
    """

    @enforce_keys [
      :kube_conn,
      :signing_key,
      :authenticate_jit,
      :mint_token,
      :verify_token,
      :lease,
      :confirm_acquisition,
      :poll,
      :ingest_chunk,
      :project_status
    ]
    defstruct kube_conn: nil,
              signing_key: nil,
              authenticate_jit: nil,
              mint_token: nil,
              verify_token: nil,
              lease: nil,
              confirm_acquisition: nil,
              poll: nil,
              ingest_chunk: nil,
              project_status: nil,
              long_poll_deadline_ms: 30_000,
              token_ttl_ms: 3_600_000

    @type claims :: %{runner_name: String.t(), job_name: String.t(), exp: non_neg_integer()}

    @type t :: %__MODULE__{
            kube_conn: term(),
            signing_key: binary(),
            authenticate_jit: (map() ->
                                 {:ok, %{runner_name: String.t(), job_name: String.t()}}
                                 | {:error, :invalid}),
            mint_token: (binary(), String.t(), String.t(), non_neg_integer() -> String.t()),
            verify_token: (binary(), String.t() ->
                             {:ok, claims()} | {:error, :expired | :invalid}),
            lease: (term(), String.t(), String.t(), non_neg_integer() ->
                      {:ok, :leased} | {:error, :lost | term()}),
            confirm_acquisition: (term(), String.t(), String.t() ->
                                    {:ok, :acquired} | {:error, :lost | term()}),
            poll: (t(), [String.t()], non_neg_integer() -> {:ok, term()} | :timeout),
            ingest_chunk: (t(), String.t(), String.t(), non_neg_integer(), String.t() ->
                             :ok | {:error, term()}),
            project_status: (term(), String.t(), String.t(), map() ->
                               {:ok, term()} | {:error, term()}),
            long_poll_deadline_ms: non_neg_integer(),
            token_ttl_ms: non_neg_integer()
          }
  end

  @doc """
  Boot the runner protocol HTTP surface bound to `port`, dispatching every
  request through `deps`. Returns `{:ok, server}` where `server` is a
  reference the caller can pass to a supervisor or stop directly.
  """
  @callback serve(Deps.t(), :inet.port_number()) :: {:ok, pid()} | {:error, term()}
end
