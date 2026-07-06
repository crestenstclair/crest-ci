defmodule MockK8s.KubeApiHttp.Server do
  @moduledoc """
  Concrete `MockK8s.KubeApiHttp` implementation: a Plug + Bandit HTTP facade
  in front of a running `MockK8s.ResourceStore`.

  `serve/2` wires three things together, none of which hold authoritative
  state:

    * a private `MockK8s.WatchHub`, fed by...
    * a `MockK8s.KubeApiHttp.Bridge`, which subscribes to `store`'s writes
      and forwards them into the hub, and
    * a `Bandit` listener running `MockK8s.KubeApiHttp.Router`, which
      translates HTTP requests into `MockK8s.ResourceStore` /
      `MockK8s.WatchHub` calls.

  All three are disposable — `stop/1` tears them down, and nothing here
  survives a restart except by reconnecting to the same `store`. This
  module never becomes a second source of truth: every request it serves
  is answered from `MockK8s.ResourceStore` (or the `WatchHub` fed
  exclusively by that store's own write events).
  """

  @behaviour MockK8s.KubeApiHttp

  alias MockK8s.KubeApiHttp.{Bridge, Router}

  @enforce_keys [:bandit, :watch_hub, :bridge]
  defstruct [:bandit, :watch_hub, :bridge]

  @type t :: %__MODULE__{bandit: pid(), watch_hub: pid(), bridge: pid()}

  @impl MockK8s.KubeApiHttp
  @spec serve(MockK8s.KubeApiHttp.store(), MockK8s.KubeApiHttp.port_number()) ::
          {:ok, MockK8s.KubeApiHttp.server()} | {:error, MockK8s.KubeApiHttp.reason()}
  def serve(store, port), do: serve(store, port, [])

  @doc """
  Same contract as `serve/2`, with extra options useful for tests and
  tuning:

    * `:backlog_limit` — forwarded to the internal `MockK8s.WatchHub`
    * `:mailbox_limit` — forwarded to the internal `MockK8s.WatchHub`
  """
  @spec serve(MockK8s.KubeApiHttp.store(), MockK8s.KubeApiHttp.port_number(), keyword()) ::
          {:ok, MockK8s.KubeApiHttp.server()} | {:error, MockK8s.KubeApiHttp.reason()}
  def serve(store, port, opts) do
    watch_hub_opts = Keyword.take(opts, [:backlog_limit, :mailbox_limit])

    with {:ok, watch_hub} <- MockK8s.WatchHub.start_link(watch_hub_opts),
         {:ok, bridge} <- Bridge.start_link(store: store, watch_hub: watch_hub),
         {:ok, bandit} <-
           Bandit.start_link(
             plug: {Router, store: store, watch_hub: watch_hub},
             port: port,
             startup_log: false
           ) do
      {:ok, %__MODULE__{bandit: bandit, watch_hub: watch_hub, bridge: bridge}}
    end
  end

  @doc "The TCP port actually bound by `server` — resolves an ephemeral `port: 0` bind."
  @spec bound_port(MockK8s.KubeApiHttp.server()) :: :inet.port_number()
  def bound_port(%__MODULE__{bandit: bandit}) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  @doc "Tear down every process `server` owns (bandit listener, bridge, watch hub)."
  @spec stop(MockK8s.KubeApiHttp.server()) :: :ok
  def stop(%__MODULE__{bandit: bandit, bridge: bridge, watch_hub: watch_hub}) do
    Enum.each([bandit, bridge, watch_hub], &stop_process/1)
    :ok
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end
end
