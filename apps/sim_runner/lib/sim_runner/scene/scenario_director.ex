defmodule SimRunner.Scene.ScenarioDirector do
  @moduledoc """
  `applicationService.Scene.ScenarioDirector` — the scene's steady-state
  workload generator.

  Submits `WorkflowRun`s built from the scene's real YAML workflow library
  (`apps/sim_runner/priv/scene_workflows/*.yml`) on a configurable trickle,
  and starts one `SimRunner.RunnerClient` per pod the reconciling controller
  creates for those runs — exactly the way `SimRunner.Demo.PodWatcher`
  already does for the existing e2e/engine demo harnesses. This module
  never reconciles a `WorkflowRun` itself and never expands YAML into a
  plan: every submitted run carries `workflowYaml` and an empty hand-built
  `plan`, so the engine's `applicationService.Controller.PlanFromDefinition`
  path (or, in this in-BEAM scene, the harness controller instance that
  stands in for it — see `SimRunner.Demo.ControllerInstance.effective_plan/1`)
  does the planning at first reconcile, exactly like a hand-planned run
  submitted by any other asset in this suite.

  ## Dependency inversion

  `start_link/1` accepts an already-composed `:kube_conn` (`{adapter_module,
  adapter_conn}`, the `port.Contract.KubeClient` pair) and `:gateway_urls` —
  this module never constructs its own Kubernetes adapter or gateway
  wiring, only consumes what the scene's boot sequence
  (`applicationService.Scene.SceneRunner`) hands it. It also accepts an
  injectable `:pod_watcher_mod` (defaulting to `SimRunner.Demo.PodWatcher`)
  so tests can substitute a stub pod watcher without a real controller
  reconciling anything.

  ## Trickle mechanism

  On start, and then every `:interval_ms` (default `5_000`), this director
  submits the next workflow in its library, cycling round-robin through the
  library in file-sorted order (`load_workflows/1` reads and sorts the
  directory once at start so the cadence is deterministic run-to-run). No
  `Process.sleep` is used anywhere — the trickle is driven entirely by
  `Process.send_after/3` self-messages, exactly like
  `SimRunner.Demo.ControllerInstance`'s own reconcile-tick loop.

  `submit_workflow_run/4` is the pure submission step, exposed as a public,
  process-independent function (mirroring
  `SimRunner.Demo.EngineOrchestrator.create_workflow_run/3`) precisely so
  `applicationService.Scene.ChaosDirector`'s `Burst` handling can submit N
  runs on demand through the exact same path — a director process is not
  required to reuse this submission logic.

  ## Idempotency

  Every submitted run gets a fresh, deterministically-named
  (`SimRunner.Demo.Naming.run_name/1`, ULID-derived) `WorkflowRun` — a
  `create` racing an existing name (vanishingly unlikely given ULID
  entropy, but handled identically to every other creator in this project)
  is tolerated as success (`{:error, :already_exists}` -> `:ok`), never
  retried as a distinct run.
  """

  use GenServer

  require Logger

  alias CrestCiContract.{Ulid, WorkflowRunSpec, WorkflowRunStatus}
  alias SimRunner.Demo.{Naming, PodWatcher}

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"
  @default_interval_ms 5_000
  @default_repo "crest-ci/scene"
  @default_ref "refs/heads/main"
  @workflow_extensions [".yml", ".yaml"]

  @typedoc "`{adapter_module, adapter_conn}` — see `CrestCiContract.KubeClient`."
  @type kube_conn :: {module(), CrestCiContract.KubeClient.conn()}

  @typedoc "One workflow library entry: its source filename and raw YAML text."
  @type workflow_entry :: {String.t(), String.t()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:kube_conn, :workflows, :interval_ms, :repo, :ref, :notify]
    defstruct [
      :kube_conn,
      :workflows,
      :interval_ms,
      :repo,
      :ref,
      :notify,
      :pod_watcher,
      submitted: 0
    ]
  end

  ## --- Public API -------------------------------------------------------

  @doc """
  Starts a `ScenarioDirector`.

  Options:

    * `:kube_conn` (required) — `{adapter_module, adapter_conn}`.
    * `:gateway_urls` (required) — passed straight to the pod watcher, which
      passes it straight to every `SimRunner.RunnerClient` it starts.
    * `:workflows` — a list of `{filename, yaml}` tuples; defaults to
      `load_workflows/1` reading `priv/scene_workflows` from this app.
    * `:interval_ms` — trickle cadence; defaults to `5_000`.
    * `:repo` / `:ref` — carried on every submitted `WorkflowRunSpec`;
      default to `"crest-ci/scene"` / `"refs/heads/main"`.
    * `:notify` — pid every started `SimRunner.RunnerClient` reports
      lifecycle messages to (via the pod watcher); defaults to the caller.
    * `:pod_watcher_mod` — module implementing `start_link/1` the same way
      `SimRunner.Demo.PodWatcher` does; defaults to
      `SimRunner.Demo.PodWatcher`. Injectable so tests can substitute a
      stub without a real controller ever creating pods.
    * `:name` — standard `GenServer` name registration option.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Submits one workflow run immediately (out of band from the trickle
  schedule), cycling to the next entry in the library the same way the
  timer-driven trickle does. Returns the created run's name.
  """
  @spec submit_now(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def submit_now(server), do: GenServer.call(server, :submit_now)

  @doc "The number of `WorkflowRun`s this director has submitted so far."
  @spec submitted_count(GenServer.server()) :: non_neg_integer()
  def submitted_count(server), do: GenServer.call(server, :submitted_count)

  @doc """
  Submits a single `WorkflowRun` carrying `workflow_yaml` (and an empty
  hand-built `plan`) through `kube_conn`. Pure with respect to process
  state — reusable by `ChaosDirector`'s `Burst` handling or tests without a
  `ScenarioDirector` process. Returns the deterministic run name on
  success; an already-existing name (see the moduledoc) is treated as
  success, same as every other creator in this project.

  Options:

    * `:ref` — defaults to `"refs/heads/main"`.
  """
  @spec submit_workflow_run(kube_conn(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def submit_workflow_run({module, conn}, repo, workflow_yaml, opts \\ [])
      when is_binary(repo) and is_binary(workflow_yaml) do
    ref = Keyword.get(opts, :ref, @default_ref)

    run_ulid = Ulid.generate()
    run_name = Naming.run_name(run_ulid)

    {:ok, spec} = WorkflowRunSpec.new(%{repo: repo, ref: ref, sha: run_ulid, plan: []})
    spec_wire = spec |> WorkflowRunSpec.to_wire() |> Map.put("workflowYaml", workflow_yaml)

    object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "WorkflowRun",
      "metadata" => %{"name" => run_name, "namespace" => @namespace},
      "spec" => spec_wire,
      "status" => WorkflowRunStatus.to_wire(WorkflowRunStatus.new(%{}))
    }

    case module.create(conn, @workflow_run_gvk, @namespace, object) do
      {:ok, _created} -> {:ok, run_name}
      {:error, :already_exists} -> {:ok, run_name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the scene workflow library from `dir` (defaults to this app's
  `priv/scene_workflows`): every `.yml`/`.yaml` file, sorted by filename so
  the trickle's round-robin cadence is deterministic run-to-run. Raises if
  the directory is missing or empty — a scene with no workflows to submit
  is a configuration error, not a degenerate empty run.
  """
  @spec load_workflows(String.t()) :: [workflow_entry()]
  def load_workflows(dir \\ default_workflows_dir()) do
    entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, @workflow_extensions))
      |> Enum.sort()
      |> Enum.map(fn filename -> {filename, File.read!(Path.join(dir, filename))} end)

    if entries == [] do
      raise "SimRunner.Scene.ScenarioDirector: no scene workflow YAML files found under #{dir}"
    end

    entries
  end

  @doc "The default scene workflow library directory: this app's `priv/scene_workflows`."
  @spec default_workflows_dir() :: String.t()
  def default_workflows_dir do
    Path.join(:code.priv_dir(:sim_runner), "scene_workflows")
  end

  ## --- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    kube_conn = Keyword.fetch!(opts, :kube_conn)
    gateway_urls = Keyword.fetch!(opts, :gateway_urls)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    workflows = Keyword.get(opts, :workflows) || load_workflows()
    repo = Keyword.get(opts, :repo, @default_repo)
    ref = Keyword.get(opts, :ref, @default_ref)
    notify = Keyword.get(opts, :notify, self())
    pod_watcher_mod = Keyword.get(opts, :pod_watcher_mod, PodWatcher)

    {:ok, pod_watcher} =
      pod_watcher_mod.start_link(
        kube_conn: kube_conn,
        gateway_urls: gateway_urls,
        notify: notify
      )

    state = %State{
      kube_conn: kube_conn,
      workflows: workflows,
      interval_ms: interval_ms,
      repo: repo,
      ref: ref,
      notify: notify,
      pod_watcher: pod_watcher
    }

    Process.flag(:trap_exit, true)
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, new_state} = do_submit(state)
    schedule_tick(state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info({:EXIT, pid, reason}, %State{pod_watcher: pid} = state) do
    Logger.warning("ScenarioDirector: pod watcher exited: #{inspect(reason)}")
    {:noreply, %{state | pod_watcher: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Defensive catch-all: `:pod_watcher_mod` is injectable (tests substitute
  # a stub), so this process may receive messages it has no fixed contract
  # with. Absorbing anything unrecognized rather than crashing keeps a
  # test double's own bookkeeping messages (or any other unanticipated
  # message) from taking this director down.
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:submit_now, _from, state) do
    {result, new_state} = do_submit(state)
    {:reply, result, new_state}
  end

  def handle_call(:submitted_count, _from, state) do
    {:reply, state.submitted, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.pod_watcher) and Process.alive?(state.pod_watcher) do
      Process.exit(state.pod_watcher, :kill)
    end

    :ok
  end

  ## --- Internal -----------------------------------------------------------

  defp do_submit(%State{workflows: workflows, submitted: submitted} = state) do
    index = rem(submitted, length(workflows))
    {_filename, workflow_yaml} = Enum.at(workflows, index)

    case submit_workflow_run(state.kube_conn, state.repo, workflow_yaml, ref: state.ref) do
      {:ok, run_name} -> {{:ok, run_name}, %{state | submitted: submitted + 1}}
      {:error, _reason} = error -> {error, state}
    end
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
