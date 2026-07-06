defmodule SimRunner.RunnerClient.Transport do
  @moduledoc """
  Port: the runner-side view of the gateway's runner protocol (v0).

  Kept narrow on purpose (Interface Segregation) — `SimRunner.RunnerClient`
  depends on exactly the six operations it calls, not a general-purpose HTTP
  client. Any module implementing this behaviour is substitutable wherever a
  transport is expected (Liskov Substitution), including test doubles.

  Endpoints this mirrors, per the Gateway's runner protocol v0:

    * `POST /session`            -> `create_session/2`
    * `GET  /session/messages`   -> `poll_messages/2`   (long-poll)
    * `POST /jobs/:name/ack`     -> `ack_job/3`
    * `POST /jobs/:name/logs`    -> `send_log_chunk/6`
    * `POST /jobs/:name/timeline`-> `send_timeline/5`
    * `POST /jobs/:name/complete`-> `complete_job/5`

  Every callback classifies failures into `:connection_error` (transport
  never reached the server) or `:server_error` (5xx) so callers can decide
  whether a retry / gateway-URL rotation is safe, versus some other
  `{:error, term}` which is treated as non-retryable.
  """

  @type base_url :: String.t()
  @type token :: String.t()
  @type job_name :: String.t()
  @type transport_error :: :connection_error | :server_error | term()

  @doc "Authenticate with the gateway's JIT config and obtain a bearer token."
  @callback create_session(base_url(), jit_config :: map()) ::
              {:ok, token()} | {:error, transport_error()}

  @doc "Long-poll for the next job message. `:no_job` means the poll deadline lapsed with nothing queued."
  @callback poll_messages(base_url(), token()) ::
              {:ok, job_message :: map()} | :no_job | {:error, transport_error()}

  @doc "Confirm acquisition of a job that was delivered by poll or assigned directly."
  @callback ack_job(base_url(), token(), job_name()) :: :ok | {:error, transport_error()}

  @doc "Upload one idempotent log chunk, identified by (job, step, seq)."
  @callback send_log_chunk(
              base_url(),
              token(),
              job_name(),
              step :: String.t(),
              seq :: pos_integer(),
              content :: String.t()
            ) ::
              :ok | {:error, transport_error()}

  @doc "Report a step's timeline status (best-effort; not required for job success)."
  @callback send_timeline(
              base_url(),
              token(),
              job_name(),
              step :: String.t(),
              status :: String.t()
            ) ::
              :ok | {:error, transport_error()}

  @doc "Report the job's final result and outputs."
  @callback complete_job(base_url(), token(), job_name(), result :: String.t(), outputs :: map()) ::
              :ok | {:error, transport_error()}
end
