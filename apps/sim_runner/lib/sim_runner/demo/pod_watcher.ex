defmodule SimRunner.Demo.PodWatcher do
  @moduledoc """
  Watches for Pod objects created by `SimRunner.Demo.ControllerInstance`
  reconciliation and starts one `SimRunner.RunnerClient` per pod, wired
  with BOTH gateway replica URLs and the pod's JIT config read straight
  from its spec — this asset's own instruction: "Start one SimRunner per
  created runner pod object (watch for pod objects, then start a
  RunnerClient with BOTH gateway URLs and the pod's JIT config from its
  spec)".

  Depends only on `CrestCiContract.KubeClient` (via the injected
  `kube_conn`), never on a concrete store — the same Dependency Inversion
  every other collaborator in this demo follows.
  """

  use GenServer

  @pod_gvk {"core", "v1", "Pod"}
  @namespace "default"

  defmodule State do
    @moduledoc false
    @enforce_keys [:gateway_urls, :notify, :started]
    defstruct [:gateway_urls, :notify, :started]
  end

  @doc """
  Starts a watcher.

  Options:

    * `:kube_conn` (required) — `{adapter_module, adapter_conn}`.
    * `:gateway_urls` (required) — passed straight to every
      `SimRunner.RunnerClient` started.
    * `:notify` — pid every started `RunnerClient` reports lifecycle
      messages to; defaults to the caller.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {module, conn} = Keyword.fetch!(opts, :kube_conn)
    gateway_urls = Keyword.fetch!(opts, :gateway_urls)
    notify = Keyword.get(opts, :notify, self())

    watcher = self()

    {:ok, _watch_ref} =
      module.watch(conn, @pod_gvk, @namespace, "0", &send(watcher, {:pod_event, &1}))

    {:ok, %State{gateway_urls: gateway_urls, notify: notify, started: MapSet.new()}}
  end

  @impl true
  def handle_info({:pod_event, {:added, pod_object}}, state) do
    name = get_in(pod_object, ["metadata", "name"])

    if name == nil or MapSet.member?(state.started, name) do
      {:noreply, state}
    else
      jit_config = get_in(pod_object, ["spec", "jitConfig"]) || %{}

      {:ok, _runner_pid} =
        SimRunner.RunnerClient.start(state.gateway_urls, jit_config, notify: state.notify)

      {:noreply, %{state | started: MapSet.put(state.started, name)}}
    end
  end

  def handle_info({:pod_event, _other}, state), do: {:noreply, state}
end
