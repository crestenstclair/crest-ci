defmodule SimRunner.RunnerClientTest do
  use ExUnit.Case, async: true

  alias SimRunner.RunnerClient

  # A scripted `SimRunner.RunnerClient.Transport` test double. Each gateway
  # URL used in a test gets its own Agent (named after the URL) holding a
  # per-call-kind handler function plus a call log, so behaviour (including
  # injected failures on a specific URL, to exercise failover) and observed
  # calls (to check chunk ordering) can both be asserted without any real
  # network I/O and without time-based synchronization.
  defmodule ScriptedTransport do
    @moduledoc false
    @behaviour SimRunner.RunnerClient.Transport

    defp default_handlers do
      %{
        create_session: fn _count, _args -> {:ok, "test-token"} end,
        poll_messages: fn _count, _args -> :no_job end,
        ack_job: fn _count, _args -> :ok end,
        send_log_chunk: fn _count, _args -> :ok end,
        send_timeline: fn _count, _args -> :ok end,
        complete_job: fn _count, _args -> :ok end
      }
    end

    def start(url, overrides \\ %{}) do
      handlers = Map.merge(default_handlers(), overrides)

      {:ok, _pid} =
        Agent.start_link(fn -> %{handlers: handlers, counts: %{}, log: []} end,
          name: registry_name(url)
        )

      :ok
    end

    def calls(url) do
      Agent.get(registry_name(url), fn state -> Enum.reverse(state.log) end)
    end

    @impl true
    def create_session(url, jit_config), do: dispatch(url, :create_session, [jit_config])
    @impl true
    def poll_messages(url, token), do: dispatch(url, :poll_messages, [token])
    @impl true
    def ack_job(url, token, job_name), do: dispatch(url, :ack_job, [token, job_name])
    @impl true
    def send_log_chunk(url, token, job_name, step, seq, content),
      do: dispatch(url, :send_log_chunk, [token, job_name, step, seq, content])

    @impl true
    def send_timeline(url, token, job_name, step, status),
      do: dispatch(url, :send_timeline, [token, job_name, step, status])

    @impl true
    def complete_job(url, token, job_name, result, outputs),
      do: dispatch(url, :complete_job, [token, job_name, result, outputs])

    defp dispatch(url, kind, args) do
      Agent.get_and_update(registry_name(url), fn state ->
        count = Map.get(state.counts, kind, 0) + 1
        handler = Map.fetch!(state.handlers, kind)
        response = handler.(count, args)

        new_state = %{
          state
          | counts: Map.put(state.counts, kind, count),
            log: [{kind, args, response} | state.log]
        }

        {response, new_state}
      end)
    end

    defp registry_name(url), do: String.to_atom("scripted_transport_" <> url)
  end

  defp unique_url(tag), do: "stub://#{tag}-#{System.unique_integer([:positive])}"

  defp job_message(overrides \\ %{}) do
    Map.merge(
      %{
        "jobName" => "build",
        "steps" => [
          %{"name" => "compile", "chunkCount" => 3},
          %{"name" => "test", "chunkCount" => 2}
        ]
      },
      overrides
    )
  end

  test "an ephemeral runner executes exactly one job and terminates in Done, emitting each event exactly once" do
    url = unique_url("single")
    :ok = ScriptedTransport.start(url)

    {:ok, pid} =
      RunnerClient.start_link(gateway_urls: [url], transport: ScriptedTransport, notify: self())

    ref = Process.monitor(pid)

    assert_receive {RunnerClient, ^pid, {:phase, :polling}}, 1000

    assert :ok = RunnerClient.execute_job(pid, job_message())

    assert_receive {RunnerClient, ^pid, {:event, {:job_acquired, %{job_name: "build"}}}}, 1000
    assert_receive {RunnerClient, ^pid, {:event, {:job_completed, completed}}}, 1000
    assert completed.job_name == "build"
    assert completed.result == "success"
    assert completed.chunks_sent == 5

    assert_receive {RunnerClient, ^pid, {:phase, :done}}, 1000
    assert_receive {RunnerClient, ^pid, {:terminal, snapshot}}, 1000
    assert snapshot.phase == :done

    # exactly one JobCompleted, no more — and the process itself terminates,
    # which is what actually enforces "exactly one job per ephemeral runner"
    # (there is no process left to accept a second ExecuteJob command).
    refute_receive {RunnerClient, ^pid, {:event, {:job_completed, _}}}, 100
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end

  test "log chunk sequence numbers per step are strictly increasing and gapless" do
    url = unique_url("chunks")
    :ok = ScriptedTransport.start(url)

    {:ok, pid} =
      RunnerClient.start_link(gateway_urls: [url], transport: ScriptedTransport, notify: self())

    assert_receive {RunnerClient, ^pid, {:phase, :polling}}, 1000

    :ok = RunnerClient.execute_job(pid, job_message())
    assert_receive {RunnerClient, ^pid, {:event, {:job_completed, _}}}, 1000

    chunk_calls =
      url
      |> ScriptedTransport.calls()
      |> Enum.filter(fn {kind, _args, _resp} -> kind == :send_log_chunk end)

    by_step =
      Enum.group_by(
        chunk_calls,
        fn {:send_log_chunk, [_token, _job, step, _seq, _content], _resp} -> step end,
        fn {:send_log_chunk, [_token, _job, _step, seq, content], _resp} -> {seq, content} end
      )

    for {_step, seqs_and_content} <- by_step do
      seqs = Enum.map(seqs_and_content, fn {seq, _content} -> seq end)
      assert seqs == Enum.to_list(1..length(seqs))

      contents = Enum.map(seqs_and_content, fn {_seq, content} -> content end)
      assert Enum.uniq(contents) == contents
    end
  end

  test "on connection failure the runner rotates to the next gateway URL and resumes the same job without restarting it" do
    url_a = unique_url("a")
    url_b = unique_url("b")

    # url_a's send_log_chunk fails once (simulating a 5xx / dropped
    # connection) on the very first chunk, then would keep failing if hit
    # again (proving the runner does not retry url_a — it fails over).
    :ok =
      ScriptedTransport.start(url_a, %{
        send_log_chunk: fn _count, _args -> {:error, :server_error} end
      })

    :ok = ScriptedTransport.start(url_b)

    {:ok, pid} =
      RunnerClient.start_link(
        gateway_urls: [url_a, url_b],
        transport: ScriptedTransport,
        notify: self()
      )

    assert_receive {RunnerClient, ^pid, {:phase, :polling}}, 1000

    :ok =
      RunnerClient.execute_job(
        pid,
        job_message(%{"steps" => [%{"name" => "compile", "chunkCount" => 1}]})
      )

    assert_receive {RunnerClient, ^pid, {:event, {:job_acquired, %{job_name: "build"}}}}, 1000
    assert_receive {RunnerClient, ^pid, {:event, {:job_completed, completed}}}, 1000
    assert completed.job_name == "build"
    assert completed.chunks_sent == 1

    assert_receive {RunnerClient, ^pid, {:terminal, snapshot}}, 1000
    assert snapshot.current_url == url_b
    assert snapshot.current_url != url_a
    assert snapshot.job_name == "build"

    # the failed URL saw exactly the one attempt that failed over — the job
    # was resumed on url_b, not restarted from scratch on url_a again.
    url_a_chunk_calls =
      url_a
      |> ScriptedTransport.calls()
      |> Enum.filter(fn {kind, _, _} -> kind == :send_log_chunk end)

    assert length(url_a_chunk_calls) == 1

    url_b_chunk_calls =
      url_b
      |> ScriptedTransport.calls()
      |> Enum.filter(fn {kind, _, _} -> kind == :send_log_chunk end)

    assert length(url_b_chunk_calls) == 1
    assert [{:send_log_chunk, [_token, "build", "compile", 1, _content], :ok}] = url_b_chunk_calls
  end

  test "a total gateway outage fails the runner without ever emitting JobCompleted" do
    url = unique_url("down")

    :ok =
      ScriptedTransport.start(url, %{
        ack_job: fn _count, _args -> {:error, :connection_error} end
      })

    {:ok, pid} =
      RunnerClient.start_link(gateway_urls: [url], transport: ScriptedTransport, notify: self())

    ref = Process.monitor(pid)
    assert_receive {RunnerClient, ^pid, {:phase, :polling}}, 1000

    :ok = RunnerClient.execute_job(pid, job_message())

    assert_receive {RunnerClient, ^pid, {:phase, :failed}}, 1000
    refute_receive {RunnerClient, ^pid, {:event, {:job_completed, _}}}, 100
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end
end
