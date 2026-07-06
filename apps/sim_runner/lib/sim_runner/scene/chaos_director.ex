defmodule SimRunner.Scene.ChaosDirector do
  @moduledoc """
  `applicationService.Scene.ChaosDirector` — executes the scene's scripted
  chaos/workload timeline against the running in-BEAM stack.

  Ticks its own `SimRunner.Scene.ChaosTimeline` (pure, data-driven —
  `ChaosTimeline.due/3`) against wall-clock elapsed time and, for every due
  `SimRunner.Scene.SceneEvent`, executes exactly one of:

    * `:kill_leader`  — kills the current controller leader's process
      (identified by reading the coordination Lease's `holderIdentity`
      through the injected `port.Contract.KubeClient`, then looked up in
      the injected `:controllers` pool) and measures the wall-clock gap
      until a *different* identity is observed holding the Lease.
    * `:kill_gateway` — kills one gateway replica's supervisor (from the
      injected `:gateways` pool) and counts how many `RunnerJob`s that were
      in-flight (`Leased`/`Acquired`) at the moment of the kill went on to
      reach `Completed` anyway — the authoritative proof, from CR state
      alone, that those runners rotated to a surviving replica rather than
      stalling.
    * `:burst` / `:submit` — submits N (or one) `WorkflowRun`s through
      `SimRunner.Scene.ScenarioDirector.submit_workflow_run/4` (or an
      injected `:submit_fun`), reusing the exact same submission path the
      steady-trickle director uses.
    * `:narrate` — emits its `detail["message"]` with no side effect.

  Every action emits exactly one narration banner line (with the measured
  before/after) to `:notify`, as a `{__MODULE__, self(), {:narration,
  line}}` message — the same lifecycle-notification convention
  `SimRunner.RunnerClient` already uses for its own phase/event messages —
  so whatever composes the scene (`applicationService.Scene.SceneRunner`)
  can fold these into its own narration/rendering loop without this module
  knowing anything about terminals, ANSI codes, or `IO.puts/1`.

  ## Dependency inversion

  `start_link/1` accepts an already-composed `:kube_conn`
  (`port.Contract.KubeClient` pair), a `:timeline` (defaulting to
  `SimRunner.Scene.ChaosTimeline.default/0`), and pools of already-started
  collaborators this director may need to kill (`:controllers`,
  `:gateways`) — this module never starts a controller instance or a
  gateway replica itself, only consumes what
  `applicationService.Scene.SceneRunner`'s boot sequence hands it. A
  `:submit_fun` seam lets tests (or an alternate scene) substitute the
  `:burst`/`:submit` submission path entirely.

  ## Measurement, never assertion

  Both `gap_ms` (KillLeader) and `rehomed_runners` (KillGateway) are
  derived by repeatedly re-reading the Lease / `RunnerJob` objects through
  `:kube_conn` after acting — never by trusting a fixed sleep duration or a
  client-side counter. `history/1` exposes every executed action's
  measured record, in execution order, so a scene's post-run verification
  pass has an authoritative-state-derived account of exactly what chaos
  ran and what it measured, without re-deriving it from scratch.

  No `Process.sleep/1` anywhere: every wait is a bounded, self-timeout
  `receive` loop (`poll_until/3`) — a due event that measures a gap or a
  settle window blocks only this director's own process, never the wider
  scene, and always resolves via an explicit deadline.
  """

  use GenServer

  alias CrestCiContract.{KubeClient, LeaseSpec, RunnerJobStatus}
  alias SimRunner.Scene.{ChaosTimeline, ScenarioDirector, SceneEvent}

  @lease_gvk {"coordination.k8s.io", "v1", "Lease"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"
  @default_lease_name "crest-ci-controller"
  @default_repo "crest-ci/scene-chaos"
  @default_tick_interval_ms 200
  @default_poll_interval_ms 20
  @default_leader_gap_timeout_ms 10_000
  @default_rehome_settle_ms 2_000

  @typedoc "`{adapter_module, adapter_conn}` — see `CrestCiContract.KubeClient`."
  @type kube_conn :: {module(), KubeClient.conn()}

  @typedoc "A killable controller instance: its Lease-holder identity and its process."
  @type controller_entry :: %{identity: String.t(), pid: pid()}

  @typedoc "A killable gateway replica: its supervisor process and base URL."
  @type gateway_entry :: %{pid: pid(), url: String.t()}

  @typedoc "One executed chaos action and what was measured about it."
  @type action_record :: %{required(:kind) => SceneEvent.kind(), optional(atom()) => term()}

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :kube_conn,
      :timeline,
      :tick_interval_ms,
      :poll_interval_ms,
      :leader_gap_timeout_ms,
      :rehome_settle_ms,
      :namespace,
      :lease_name,
      :notify,
      :submit_fun,
      :start_ms
    ]
    defstruct [
      :kube_conn,
      :timeline,
      :tick_interval_ms,
      :poll_interval_ms,
      :leader_gap_timeout_ms,
      :rehome_settle_ms,
      :namespace,
      :lease_name,
      :notify,
      :submit_fun,
      :start_ms,
      controllers: [],
      gateways: [],
      already_fired: MapSet.new(),
      history: []
    ]
  end

  ## --- Public API -------------------------------------------------------

  @doc """
  Starts a `ChaosDirector`.

  Options:

    * `:kube_conn` (required) — `{adapter_module, adapter_conn}`.
    * `:timeline` — defaults to `SimRunner.Scene.ChaosTimeline.default/0`.
    * `:controllers` — `[%{identity: String.t(), pid: pid()}]`; the pool
      `:kill_leader` may kill. Defaults to `[]` (a scheduled `KillLeader`
      with no known controller pid is narrated and skipped, never raises).
    * `:gateways` — `[%{pid: pid(), url: String.t()}]`; the pool
      `:kill_gateway` may kill, tried in list order. Defaults to `[]`
      (same skip-and-narrate behavior once exhausted).
    * `:namespace` — defaults to `"default"`.
    * `:lease_name` — the coordination Lease to read the leader from;
      defaults to `"crest-ci-controller"`.
    * `:repo` — carried on runs `:burst`/`:submit` create via the default
      `:submit_fun`; defaults to `"crest-ci/scene-chaos"`.
    * `:workflows` — `[{filename, yaml}]` used by the default
      `:submit_fun`; defaults to
      `SimRunner.Scene.ScenarioDirector.load_workflows/0`.
    * `:submit_fun` — a zero-arity function returning `{:ok, run_name} |
      {:error, term()}`, called once per run for `:burst`/`:submit`
      events; defaults to submitting the first library workflow via
      `SimRunner.Scene.ScenarioDirector.submit_workflow_run/4`.
    * `:tick_interval_ms` — how often the timeline is checked for due
      events; defaults to `200`.
    * `:poll_interval_ms` — cadence of the internal measurement polls;
      defaults to `20`.
    * `:leader_gap_timeout_ms` — how long `:kill_leader` waits for a new
      leader before giving up (`gap_ms: nil` in its record); defaults to
      `10_000`.
    * `:rehome_settle_ms` — how long `:kill_gateway` waits for in-flight
      jobs to reach `Completed` before counting whatever settled so far;
      defaults to `2_000`.
    * `:notify` — pid narration/lifecycle messages are sent to; defaults
      to the caller.
    * `:name` — standard `GenServer` name registration option.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Every chaos action executed so far, in execution order, with its measured record."
  @spec history(GenServer.server()) :: [action_record()]
  def history(server), do: GenServer.call(server, :history)

  ## --- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    kube_conn = Keyword.fetch!(opts, :kube_conn)
    repo = Keyword.get(opts, :repo, @default_repo)

    state = %State{
      kube_conn: kube_conn,
      timeline: Keyword.get(opts, :timeline, ChaosTimeline.default()),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      leader_gap_timeout_ms:
        Keyword.get(opts, :leader_gap_timeout_ms, @default_leader_gap_timeout_ms),
      rehome_settle_ms: Keyword.get(opts, :rehome_settle_ms, @default_rehome_settle_ms),
      namespace: Keyword.get(opts, :namespace, @namespace),
      lease_name: Keyword.get(opts, :lease_name, @default_lease_name),
      notify: Keyword.get(opts, :notify, self()),
      submit_fun: Keyword.get(opts, :submit_fun, default_submit_fun(kube_conn, opts, repo)),
      start_ms: System.monotonic_time(:millisecond),
      controllers: Keyword.get(opts, :controllers, []),
      gateways: Keyword.get(opts, :gateways, [])
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_ms
    {due, already_fired} = ChaosTimeline.due(state.timeline, elapsed_ms, state.already_fired)

    state =
      due
      |> Enum.reduce(%{state | already_fired: already_fired}, &execute_event/2)

    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  ## --- Event dispatch ------------------------------------------------------

  defp execute_event(%SceneEvent{kind: :kill_leader}, state), do: do_kill_leader(state)
  defp execute_event(%SceneEvent{kind: :kill_gateway}, state), do: do_kill_gateway(state)

  defp execute_event(%SceneEvent{kind: :burst, detail: detail}, state),
    do: do_burst(state, detail)

  defp execute_event(%SceneEvent{kind: :submit}, state), do: do_burst(state, %{count: 1})

  defp execute_event(%SceneEvent{kind: :narrate, detail: detail}, state) do
    narrate(state, fetch_any(detail, [:message, "message"], ""))
    record_action(state, %{kind: :narrate})
  end

  ## --- KillLeader ----------------------------------------------------------

  defp do_kill_leader(state) do
    case current_leader(state) do
      {:ok, identity} -> kill_leader_identity(state, identity)
      :none -> skip(state, "CHAOS KillLeader: no leader currently elected — skipping")
    end
  end

  defp kill_leader_identity(state, identity) do
    case find_controller(state, identity) do
      {:ok, pid} ->
        start_ms = System.monotonic_time(:millisecond)
        safe_kill(pid)
        gap_ms = wait_for_new_leader(state, identity, start_ms)

        narrate(state, kill_leader_line(identity, gap_ms))
        record_action(state, %{kind: :kill_leader, killed_identity: identity, gap_ms: gap_ms})

      :not_found ->
        skip(
          state,
          "CHAOS KillLeader: leader #{identity} has no known controller pid to kill — skipping"
        )
    end
  end

  defp kill_leader_line(identity, nil) do
    "CHAOS KillLeader: killed #{identity} — no new leader observed before timeout"
  end

  defp kill_leader_line(identity, gap_ms) do
    "CHAOS KillLeader: killed #{identity} — new leader acquired after #{gap_ms}ms"
  end

  defp current_leader(%State{
         kube_conn: {module, conn},
         namespace: namespace,
         lease_name: lease_name
       }) do
    with {:ok, object} <- module.get(conn, @lease_gvk, namespace, lease_name),
         {:ok, %LeaseSpec{holder_identity: identity}} <-
           LeaseSpec.from_wire(Map.get(object, "spec", %{})) do
      {:ok, identity}
    else
      _other -> :none
    end
  end

  defp wait_for_new_leader(state, old_identity, start_ms) do
    deadline_ms = start_ms + state.leader_gap_timeout_ms

    check = fn ->
      case current_leader(state) do
        {:ok, identity} when identity != old_identity -> {:ok, identity}
        _other -> :continue
      end
    end

    case poll_until(deadline_ms, state.poll_interval_ms, check) do
      {:ok, _new_identity} -> System.monotonic_time(:millisecond) - start_ms
      :timeout -> nil
    end
  end

  defp find_controller(%State{controllers: controllers}, identity) do
    case Enum.find(controllers, &(&1.identity == identity)) do
      %{pid: pid} -> {:ok, pid}
      nil -> :not_found
    end
  end

  ## --- KillGateway -----------------------------------------------------------

  defp do_kill_gateway(%State{gateways: []} = state) do
    skip(state, "CHAOS KillGateway: no gateway replicas remaining to kill — skipping")
  end

  defp do_kill_gateway(%State{gateways: [gateway | remaining]} = state) do
    candidates = in_flight_job_names(state)
    safe_kill(gateway.pid)
    rehomed = wait_and_count_rehomed(state, candidates)

    narrate(state, kill_gateway_line(gateway.url, length(candidates), rehomed))

    %{state | gateways: remaining}
    |> record_action(%{
      kind: :kill_gateway,
      killed_url: gateway.url,
      at_risk: length(candidates),
      rehomed_runners: rehomed
    })
  end

  defp kill_gateway_line(url, 0, _rehomed) do
    "CHAOS KillGateway: killed #{url} — no in-flight runners at risk"
  end

  defp kill_gateway_line(url, at_risk, rehomed) do
    "CHAOS KillGateway: killed #{url} — #{at_risk} in-flight runner(s) at risk, #{rehomed} re-homed and completed"
  end

  defp in_flight_job_names(%State{kube_conn: {module, conn}, namespace: namespace}) do
    case module.list(conn, @runner_job_gvk, namespace, []) do
      {:ok, objects, _continue} ->
        objects
        |> Enum.filter(&in_flight?/1)
        |> Enum.map(&get_in(&1, ["metadata", "name"]))
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp in_flight?(object) do
    case RunnerJobStatus.from_wire(Map.get(object, "status", %{})) do
      {:ok, %RunnerJobStatus{phase: phase}} -> phase in [:leased, :acquired]
      {:error, _reason} -> false
    end
  end

  defp wait_and_count_rehomed(_state, []), do: 0

  defp wait_and_count_rehomed(state, candidates) do
    deadline_ms = System.monotonic_time(:millisecond) + state.rehome_settle_ms

    check = fn ->
      completed = completed_count(state, candidates)
      if completed == length(candidates), do: {:ok, completed}, else: :continue
    end

    case poll_until(deadline_ms, state.poll_interval_ms, check) do
      {:ok, completed} -> completed
      :timeout -> completed_count(state, candidates)
    end
  end

  defp completed_count(%State{kube_conn: {module, conn}, namespace: namespace}, candidates) do
    Enum.count(candidates, fn name ->
      case module.get(conn, @runner_job_gvk, namespace, name) do
        {:ok, object} ->
          case RunnerJobStatus.from_wire(Map.get(object, "status", %{})) do
            {:ok, %RunnerJobStatus{phase: :completed}} -> true
            _other -> false
          end

        {:error, _reason} ->
          false
      end
    end)
  end

  ## --- Burst / Submit --------------------------------------------------------

  defp do_burst(state, detail) do
    count = fetch_count(detail)

    submitted =
      if count > 0 do
        Enum.count(1..count, fn _i -> match?({:ok, _run_name}, state.submit_fun.()) end)
      else
        0
      end

    narrate(state, "CHAOS Burst: submitted #{submitted}/#{count} workflow run(s)")
    record_action(state, %{kind: :burst, requested: count, submitted: submitted})
  end

  defp fetch_count(detail) do
    case fetch_any(detail, [:count, "count"], 1) do
      count when is_integer(count) and count > 0 -> count
      _other -> 1
    end
  end

  defp default_submit_fun(kube_conn, opts, repo) do
    workflows = Keyword.get(opts, :workflows) || ScenarioDirector.load_workflows()
    {_filename, workflow_yaml} = hd(workflows)

    fn -> ScenarioDirector.submit_workflow_run(kube_conn, repo, workflow_yaml) end
  end

  ## --- Shared helpers --------------------------------------------------------

  defp skip(state, line) do
    narrate(state, line)
    record_action(state, %{kind: :skipped})
  end

  defp record_action(state, record) do
    %{state | history: state.history ++ [record]}
  end

  defp narrate(%State{notify: notify}, line) when is_binary(line) do
    send(notify, {__MODULE__, self(), {:narration, line}})
    :ok
  end

  defp safe_kill(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp fetch_any(map, keys, default) when is_map(map) do
    case Enum.find_value(keys, fn key ->
           if Map.has_key?(map, key), do: {:found, Map.get(map, key)}
         end) do
      {:found, value} -> value
      nil -> default
    end
  end

  defp fetch_any(_map, _keys, default), do: default

  # Bounded, self-timeout wait: no `Process.sleep/1` anywhere. `check.()`
  # returns `{:ok, value}` once satisfied or `:continue` otherwise; this
  # loop re-checks every `interval_ms` via a `receive ... after` deadline
  # (never matching an actual message) until either `check` is satisfied or
  # `deadline_ms` (monotonic time) has passed.
  defp poll_until(deadline_ms, interval_ms, check) do
    case check.() do
      {:ok, value} ->
        {:ok, value}

      :continue ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          :timeout
        else
          receive do
          after
            interval_ms -> poll_until(deadline_ms, interval_ms, check)
          end
        end
    end
  end
end
