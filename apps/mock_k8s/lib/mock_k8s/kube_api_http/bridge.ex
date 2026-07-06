defmodule MockK8s.KubeApiHttp.Bridge do
  @moduledoc """
  Forwards every `MockK8s.ResourceStore` write into the `MockK8s.WatchHub`
  that `MockK8s.KubeApiHttp.Router`'s `?watch=true` endpoints read from.

  Holds no authoritative state of its own — only "which store, which
  hub" — so if it crashes, `MockK8s.KubeApiHttp.Server` restarting it
  (alongside the rest of the server) loses nothing: the next `subscribe/2`
  call just re-registers with the store. `ResourceStore` write events do not
  carry a `gvk` themselves, so this module recovers it from the object's
  `apiVersion` + `kind` fields via `MockK8s.KubeApiHttp.Kinds`, which every
  object written through the router has stamped on it.
  """

  use GenServer

  alias MockK8s.KubeApiHttp.Kinds
  alias MockK8s.{ResourceStore, WatchHub}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    watch_hub = Keyword.fetch!(opts, :watch_hub)
    :ok = ResourceStore.subscribe(store, self())
    {:ok, %{store: store, watch_hub: watch_hub}}
  end

  @impl true
  def handle_info({:resource_written, event}, state) do
    case to_watch_hub_event(event) do
      {:ok, hub_event} -> :ok = WatchHub.notify(state.watch_hub, hub_event)
      {:error, _reason} -> :ok
    end

    {:noreply, state}
  end

  defp to_watch_hub_event(%{type: type, object: object, resource_version: rv}) do
    with {:ok, gvk} <- Kinds.gvk_from_object(object) do
      namespace = get_in(object, ["metadata", "namespace"]) || ""
      {:ok, %{type: type, gvk: gvk, namespace: namespace, resource_version: rv, object: object}}
    end
  end
end
