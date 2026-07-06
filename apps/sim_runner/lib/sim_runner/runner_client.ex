defmodule SimRunner.RunnerClient do
  @moduledoc """
  The runner lifecycle state machine: `Connecting -> Polling -> Executing ->
  Reporting -> Done | Failed`.

  A `RunnerClient` is an ephemeral, protocol-real simulated runner: one
  process that walks session -> poll -> acquire -> execute (simulated) ->
  stream logs -> complete, exactly once, and then terminates. It holds no
  authority of its own — the gateway/controller custom resources are the
  source of truth; this process is just the client side of that protocol.

  ## Dependency inversion

  `RunnerClient` depends on the narrow `SimRunner.RunnerClient.Transport`
  behaviour, never on a concrete HTTP client. `start_link/1` accepts a
  `:transport` module (defaulting to `SimRunner.RunnerClient.HttpTransport`
  for production use); tests inject a stub/mock implementing the same
  behaviour instead, so the whole state machine is testable without any
  network I/O.

  ## Failover

  `RunnerClient` is given a LIST of gateway base URLs. On a connection
  failure or 5xx from the currently-selected URL, it rotates to the next URL
  in the list and retries the SAME operation with the SAME session token —
  it never re-authenticates and never restarts the job in progress. A retry
  attempt is bounded to one full cycle through `gateway_urls` so a total
  outage fails the operation instead of looping forever (no `Process.sleep`,
  no busy loops — the poll loop reschedules itself via `Process.send_after`).

  ## Job message shape

  `execute_job/2` and the internal poll loop both accept a job message as a
  plain map:

      %{
        "jobName" => "build",
        "steps" => [%{"name" => "compile", "chunkCount" => 5}, ...],
        "result" => "success"   # optional, defaults to "success"
      }

  ## Lifecycle notifications

  The process that starts a `RunnerClient` (or whichever pid is passed as
  `:notify`) receives messages of the shape
  `{SimRunner.RunnerClient, pid, {:phase, phase}}` on every phase transition
  and `{SimRunner.RunnerClient, pid, {:event, event}}` for the two aggregate
  events (`{:job_acquired, %{job_name: ...}}` and
  `{:job_completed, %{job_name: ..., result: ..., chunks_sent: ...}}`).
  Immediately before terminating, it also sends a
  `{SimRunner.RunnerClient, pid, {:terminal, snapshot}}` message carrying a
  final state snapshot — this lets callers/tests observe end-of-life state
  (e.g. which gateway URL ended up current) without racing process exit.
  """

  use GenServer

  require Logger

  alias SimRunner.RunnerClient.HttpTransport

  @type phase :: :connecting | :polling | :executing | :reporting | :done | :failed

  @type job_acquired_event :: {:job_acquired, %{job_name: String.t()}}
  @type job_completed_event ::
          {:job_completed,
           %{job_name: String.t(), result: String.t(), chunks_sent: non_neg_integer()}}
  @type event :: job_acquired_event() | job_completed_event()

  defmodule State do
    @moduledoc false
    @enforce_keys [:gateway_urls, :current_url, :transport, :notify]
    defstruct [
      :gateway_urls,
      :current_url,
      :transport,
      :notify,
      :jit_config,
      :session_token,
      :job_name,
      :poll_interval_ms,
      phase: :connecting,
      chunks_sent: 0,
      chunk_seqs: %{}
    ]
  end

  ## --- Public API -----------------------------------------------------

  @doc """
  Start a runner: the `RunnerClient.Start(gatewayUrls, jitConfig) ->
  RunnerClient` command. Convenience wrapper around `start_link/1` taking
  the aggregate's declared positional payload.
  """
  @spec start(list(String.t()), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(gateway_urls, jit_config, opts \\ [])
      when is_list(gateway_urls) and is_map(jit_config) do
    opts
    |> Keyword.merge(gateway_urls: gateway_urls, jit_config: jit_config)
    |> start_link()
  end

  @doc """
  Start a runner GenServer.

  Options:

    * `:gateway_urls` (required) — non-empty list of gateway base URLs.
    * `:jit_config` — map passed to `create_session/2`; defaults to `%{}`.
    * `:transport` — module implementing `SimRunner.RunnerClient.Transport`;
      defaults to `SimRunner.RunnerClient.HttpTransport`.
    * `:notify` — pid to receive lifecycle messages; defaults to the caller.
    * `:poll_interval_ms` — delay between long-poll attempts when no job is
      waiting; defaults to `25`.
    * `:name` — standard `GenServer` name registration option.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    gateway_urls = Keyword.fetch!(opts, :gateway_urls)

    if gateway_urls == [] do
      raise ArgumentError, "gateway_urls must be a non-empty list"
    end

    init_arg = %{
      gateway_urls: gateway_urls,
      jit_config: Keyword.get(opts, :jit_config, %{}),
      transport: Keyword.get(opts, :transport, HttpTransport),
      notify: Keyword.get(opts, :notify, self()),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 25)
    }

    GenServer.start_link(__MODULE__, init_arg, Keyword.take(opts, [:name]))
  end

  @doc """
  The `RunnerClient.ExecuteJob(jobMessage) -> ok` command. Directly assigns
  a job to the runner (bypassing the poll loop) — used by tests and by
  harnesses driving the runner without a live gateway. Returns `:ok`
  immediately; the runner executes the job asynchronously and reports
  progress via lifecycle messages.

  Returns `{:error, :not_connected}` if the initial session hasn't been
  established yet, or `{:error, :job_already_assigned}` if a job has
  already been assigned — an ephemeral runner executes exactly one job.
  """
  @spec execute_job(GenServer.server(), map()) ::
          :ok | {:error, :not_connected} | {:error, :job_already_assigned}
  def execute_job(server, job_message) when is_map(job_message) do
    GenServer.call(server, {:execute_job, job_message})
  end

  @doc "Current lifecycle phase."
  @spec phase(GenServer.server()) :: phase()
  def phase(server), do: GenServer.call(server, :phase)

  @doc "A snapshot of the runner's current state, for introspection/tests."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  ## --- GenServer callbacks: init --------------------------------------

  @impl true
  def init(init_arg) do
    state = %State{
      gateway_urls: init_arg.gateway_urls,
      current_url: hd(init_arg.gateway_urls),
      transport: init_arg.transport,
      notify: init_arg.notify,
      jit_config: init_arg.jit_config,
      poll_interval_ms: init_arg.poll_interval_ms
    }

    {:ok, state, {:continue, :connect}}
  end

  ## --- GenServer callbacks: handle_continue ---------------------------

  @impl true
  def handle_continue(:connect, state) do
    case with_failover(state, fn url -> state.transport.create_session(url, state.jit_config) end) do
      {:ok, token, new_state} ->
        new_state = set_phase(%{new_state | session_token: token}, :polling)
        {:noreply, new_state, {:continue, :poll_once}}

      {:error, _reason, new_state} ->
        {:stop, :normal, terminate_failed(new_state)}
    end
  end

  def handle_continue(:poll_once, %State{phase: :polling} = state) do
    case with_failover(state, fn url ->
           state.transport.poll_messages(url, state.session_token)
         end) do
      {:ok, job_message, new_state} when is_map(job_message) ->
        do_execute_job(job_message, new_state)

      {:ok, :no_job, new_state} ->
        Process.send_after(self(), :poll_tick, new_state.poll_interval_ms)
        {:noreply, new_state}

      {:error, _reason, new_state} ->
        Process.send_after(self(), :poll_tick, new_state.poll_interval_ms)
        {:noreply, new_state}
    end
  end

  def handle_continue(:poll_once, state), do: {:noreply, state}

  def handle_continue({:execute_job, job_message}, state) do
    do_execute_job(job_message, state)
  end

  ## --- GenServer callbacks: handle_call --------------------------------

  @impl true
  def handle_call({:execute_job, _job_message}, _from, %State{phase: :connecting} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:execute_job, job_message}, _from, %State{phase: :polling} = state) do
    {:reply, :ok, state, {:continue, {:execute_job, job_message}}}
  end

  def handle_call({:execute_job, _job_message}, _from, state) do
    {:reply, {:error, :job_already_assigned}, state}
  end

  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  ## --- GenServer callbacks: handle_info --------------------------------

  @impl true
  def handle_info(:poll_tick, %State{phase: :polling} = state) do
    {:noreply, state, {:continue, :poll_once}}
  end

  def handle_info(:poll_tick, state), do: {:noreply, state}

  ## --- Job execution ----------------------------------------------------

  defp do_execute_job(job_message, state) do
    job_name = fetch_any(job_message, ["jobName", "job_name", :jobName, :job_name], "unnamed-job")
    state = %{state | job_name: job_name}
    state = set_phase(state, :executing)

    case with_failover(state, fn url ->
           state.transport.ack_job(url, state.session_token, job_name)
         end) do
      {:ok, _ack, state} ->
        state = emit_event(state, {:job_acquired, %{job_name: job_name}})
        run_steps(job_message, state)

      {:error, reason, state} ->
        Logger.warning(
          "SimRunner.RunnerClient: failed to acquire job #{job_name}: #{inspect(reason)}"
        )

        {:stop, :normal, terminate_failed(state)}
    end
  end

  defp run_steps(job_message, state) do
    steps = fetch_any(job_message, ["steps", :steps], [])
    result = fetch_any(job_message, ["result", :result], "success")

    case Enum.reduce_while(steps, {:ok, state}, &run_one_step/2) do
      {:ok, state} -> complete(state, result)
      {:error, state} -> {:stop, :normal, terminate_failed(state)}
    end
  end

  defp run_one_step(step, {:ok, state}) do
    step_name = fetch_any(step, ["name", :name], "step")
    chunk_count = fetch_any(step, ["chunkCount", "chunk_count", :chunkCount, :chunk_count], 3)

    state = report_step_running(state, step_name)

    case send_chunks(state, step_name, chunk_count, 1) do
      {:ok, new_state} -> {:cont, {:ok, new_state}}
      {:error, new_state} -> {:halt, {:error, new_state}}
    end
  end

  defp report_step_running(state, step_name) do
    case with_failover(state, fn url ->
           state.transport.send_timeline(
             url,
             state.session_token,
             state.job_name,
             step_name,
             "running"
           )
         end) do
      {:ok, _ok, new_state} ->
        new_state

      {:error, reason, new_state} ->
        Logger.warning(
          "SimRunner.RunnerClient: timeline update failed (non-fatal): #{inspect(reason)}"
        )

        new_state
    end
  end

  # Sends chunks 1..chunk_count for a step, in order. On a retryable
  # transport error the SAME (unadvanced) seq is retried across gateway URL
  # failover — the seq counter (and thus `chunks_sent`) only advances once a
  # chunk is confirmed sent, so a resend after reconnect is always the last
  # unacknowledged chunk, never a skip or a rewind.
  defp send_chunks(state, _step_name, chunk_count, seq) when seq > chunk_count do
    {:ok, state}
  end

  defp send_chunks(state, step_name, chunk_count, seq) do
    content = "#{step_name} chunk #{seq}"

    case with_failover(state, fn url ->
           state.transport.send_log_chunk(
             url,
             state.session_token,
             state.job_name,
             step_name,
             seq,
             content
           )
         end) do
      {:ok, _ok, new_state} ->
        new_state = %{
          new_state
          | chunks_sent: new_state.chunks_sent + 1,
            chunk_seqs: Map.put(new_state.chunk_seqs, step_name, seq)
        }

        send_chunks(new_state, step_name, chunk_count, seq + 1)

      {:error, reason, new_state} ->
        Logger.warning(
          "SimRunner.RunnerClient: failed to send chunk #{seq} for step #{step_name}: #{inspect(reason)}"
        )

        {:error, new_state}
    end
  end

  defp complete(state, result) do
    outputs = %{}

    case with_failover(state, fn url ->
           state.transport.complete_job(url, state.session_token, state.job_name, result, outputs)
         end) do
      {:ok, _ok, state} ->
        state = set_phase(state, :reporting)

        state =
          emit_event(
            state,
            {:job_completed,
             %{job_name: state.job_name, result: result, chunks_sent: state.chunks_sent}}
          )

        state = set_phase(state, :done)
        {:stop, :normal, terminate_ok(state)}

      {:error, reason, state} ->
        Logger.warning("SimRunner.RunnerClient: failed to report completion: #{inspect(reason)}")
        {:stop, :normal, terminate_failed(state)}
    end
  end

  ## --- Failover ----------------------------------------------------------

  # Tries `fun` (a function of the current URL) against `state.current_url`;
  # on a retryable transport error, rotates to the next gateway URL and
  # retries the SAME operation (same token, same job — never restarted),
  # bounded to one full cycle through `gateway_urls`.
  defp with_failover(state, fun), do: try_urls(state, fun, length(state.gateway_urls))

  defp try_urls(state, _fun, 0), do: {:error, :all_gateway_urls_failed, state}

  defp try_urls(state, fun, attempts_left) do
    case fun.(state.current_url) do
      :ok ->
        {:ok, :ok, state}

      {:ok, result} ->
        {:ok, result, state}

      :no_job ->
        {:ok, :no_job, state}

      {:error, reason} when reason in [:connection_error, :server_error] ->
        next_url = next_gateway_url(state.gateway_urls, state.current_url)
        try_urls(%{state | current_url: next_url}, fun, attempts_left - 1)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp next_gateway_url(urls, current) do
    index = Enum.find_index(urls, &(&1 == current)) || 0
    Enum.at(urls, rem(index + 1, length(urls)))
  end

  ## --- Termination ---------------------------------------------------

  defp terminate_ok(state) do
    notify_terminal(state)
    state
  end

  defp terminate_failed(state) do
    state = set_phase(state, :failed)
    notify_terminal(state)
    state
  end

  defp notify_terminal(state) do
    send(state.notify, {__MODULE__, self(), {:terminal, snapshot_of(state)}})
  end

  defp snapshot_of(state) do
    %{
      phase: state.phase,
      job_name: state.job_name,
      current_url: state.current_url,
      gateway_urls: state.gateway_urls,
      chunks_sent: state.chunks_sent
    }
  end

  ## --- Notifications ------------------------------------------------

  defp set_phase(state, phase) do
    send(state.notify, {__MODULE__, self(), {:phase, phase}})
    %{state | phase: phase}
  end

  defp emit_event(state, event) do
    send(state.notify, {__MODULE__, self(), {:event, event}})
    state
  end

  ## --- Helpers ---------------------------------------------------------

  # Looks up the first of `keys` present in `map` (tried in order, so both
  # camelCase-wire and snake_case/atom forms can be supported without any
  # dynamic atom creation), falling back to `default` if none match.
  defp fetch_any(map, keys, default) when is_map(map) do
    case Enum.find_value(keys, fn key ->
           if Map.has_key?(map, key), do: {:found, Map.get(map, key)}
         end) do
      {:found, value} -> value
      nil -> default
    end
  end

  defp fetch_any(_map, _keys, default), do: default
end
