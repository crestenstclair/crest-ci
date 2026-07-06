defmodule MockK8s.ResourceStore do
  @moduledoc """
  The single authoritative object store: all reads, writes, and CAS
  arbitration for every group/version/kind the mock Kubernetes API serves.

  This is the one OTP process in `MockK8s` allowed to hold source-of-truth
  state — it stands in for etcd, so unlike every other component in this
  project (controller, gateway) it is *supposed* to be the place truth
  lives. All actual write semantics — monotonic resourceVersions, CAS,
  status-subresource isolation — live in the pure
  `MockK8s.ResourceStore.Core` module; this GenServer is only the OTP edge
  that serializes access to it and fans successful writes out to
  subscribers.

  Subscribers are plain pids registered at runtime via `subscribe/2` /
  `unsubscribe/2` — never a hardcoded collaborator module — so a watch hub
  (or a test process) can attach and detach without this module knowing
  anything about who is listening. On every successful write each
  subscriber receives exactly one `{:resource_written, event}` message.

  Started explicitly with `start_link/1` (optionally `port: 0`-style
  ephemeral wiring is the HTTP adapter's concern, not this module's) — no
  app binds anything at boot.
  """

  use GenServer

  alias MockK8s.ResourceStore.Core

  @type server :: GenServer.server()

  # -- Client API --------------------------------------------------------

  @doc "Start a resource store. Accepts the standard GenServer `:name` option."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opts, _opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, :ok, name_opts)
  end

  @doc """
  Create a new object under `{gvk, namespace, name}` (name read from
  `object["metadata"]["name"]`).

  Returns `{:error, :already_exists}` — never a duplicate — if the key is
  already occupied.
  """
  @spec create(server(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def create(server, gvk, namespace, object) do
    GenServer.call(server, {:create, gvk, namespace, object})
  end

  @doc """
  Replace an existing object's spec + metadata via optimistic concurrency
  keyed on `object["metadata"]["resourceVersion"]`. Never touches `status`.
  Returns `{:error, :conflict}` on a stale resourceVersion.
  """
  @spec update(server(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def update(server, gvk, namespace, object) do
    GenServer.call(server, {:update, gvk, namespace, object})
  end

  @doc """
  Replace only the `status` subtree of an existing object via optimistic
  concurrency on `expected_resource_version`. Returns `{:error, :conflict}`
  on a stale resourceVersion.
  """
  @spec patch_status(server(), String.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def patch_status(server, gvk, namespace, name, status, expected_resource_version) do
    GenServer.call(
      server,
      {:patch_status, gvk, namespace, name, status, expected_resource_version}
    )
  end

  @doc "Delete an object. Returns `{:error, :not_found}` if it does not exist."
  @spec delete(server(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def delete(server, gvk, namespace, name) do
    GenServer.call(server, {:delete, gvk, namespace, name})
  end

  @doc "Fetch a single object by identity."
  @spec get(server(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(server, gvk, namespace, name) do
    GenServer.call(server, {:get, gvk, namespace, name})
  end

  @doc """
  List objects for `{gvk, namespace}`. `opts[:limit]` caps the page size;
  `opts[:continue]` resumes from a previous call's continue token. See
  `MockK8s.ResourceStore.Core.list/4` for the pagination contract.
  """
  @spec list(server(), String.t(), String.t(), keyword()) :: {:ok, [map()], String.t() | nil}
  def list(server, gvk, namespace, opts \\ []) do
    GenServer.call(server, {:list, gvk, namespace, opts})
  end

  @doc """
  Register `pid` (defaults to the caller) to receive `{:resource_written,
  event}` for every subsequent successful write across all kinds. Exactly
  one message is sent per successful write.
  """
  @spec subscribe(server(), pid()) :: :ok
  def subscribe(server, pid \\ self()) do
    GenServer.call(server, {:subscribe, pid})
  end

  @doc "Stop delivering write notifications to `pid` (defaults to the caller)."
  @spec unsubscribe(server(), pid()) :: :ok
  def unsubscribe(server, pid \\ self()) do
    GenServer.call(server, {:unsubscribe, pid})
  end

  # -- Server callbacks ----------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %{core: Core.new(), subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:create, gvk, namespace, object}, _from, state) do
    dispatch_write(state, fn core -> Core.create(core, gvk, namespace, object) end)
  end

  def handle_call({:update, gvk, namespace, object}, _from, state) do
    dispatch_write(state, fn core -> Core.update(core, gvk, namespace, object) end)
  end

  def handle_call({:patch_status, gvk, namespace, name, status, expected_rv}, _from, state) do
    dispatch_write(state, fn core ->
      Core.patch_status(core, gvk, namespace, name, status, expected_rv)
    end)
  end

  def handle_call({:delete, gvk, namespace, name}, _from, state) do
    case Core.delete(state.core, gvk, namespace, name) do
      {:ok, new_core, _object, event} ->
        broadcast(state.subscribers, event)
        {:reply, :ok, %{state | core: new_core}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get, gvk, namespace, name}, _from, state) do
    {:reply, Core.get(state.core, gvk, namespace, name), state}
  end

  def handle_call({:list, gvk, namespace, opts}, _from, state) do
    {:reply, Core.list(state.core, gvk, namespace, opts), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # -- helpers -------------------------------------------------------------

  # Shared shape for Create/Update/PatchStatus: run the Core operation,
  # broadcast the WatchEvent exactly once on success, and reply with the
  # written object without leaking Core's internal state/event tuple.
  defp dispatch_write(state, core_fun) do
    case core_fun.(state.core) do
      {:ok, new_core, object, event} ->
        broadcast(state.subscribers, event)
        {:reply, {:ok, object}, %{state | core: new_core}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, fn pid -> send(pid, {:resource_written, event}) end)
  end
end
