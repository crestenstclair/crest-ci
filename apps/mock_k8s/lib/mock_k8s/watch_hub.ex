defmodule MockK8s.WatchHub do
  @moduledoc """
  Fans out `ResourceWritten` events to watch subscribers, ordered and
  resumable.

  `WatchHub` is deliberately NOT a source of truth: it holds only a bounded,
  replayable window of recently written events (per `gvk`) plus the set of
  currently-open watches. Losing this process loses nothing authoritative —
  a subscriber that reconnects after a crash either relists (fresh
  `fromResourceVersion`) or gets `{:error, :gone}` and is told to relist,
  which is the correct, expected behavior for any Kubernetes-style watch
  stream. Authoritative object state and `resourceVersion` assignment live in
  the resource store; this module only distributes already-committed events.

  ## State

    * `backlog` — bounded event history per `gvk`, used to replay history to
      a subscriber joining from an already-seen `resourceVersion`.
    * `subscribers` — one entry per open watch: `watch_ref => {gvk,
      namespace, last_delivered_rv}` (plus the delivery pid and this
      subscriber's mailbox bound), used to scope live dispatch and detect a
      slow subscriber that must be terminated.

  ## Delivery discipline

  Dispatch to subscriber processes uses `Kernel.send/2`, which never blocks
  the caller. Before sending, each subscriber's outstanding mailbox depth is
  checked (`Process.info/2`); a subscriber whose queue has grown past its
  bound is terminated (removed from `subscribers` and sent one
  `{:watch_terminated, watch_ref, :overflow}` message) instead of receiving
  the event. This bounds the cost of `notify/2` to "iterate current
  subscribers, non-blocking send to each" regardless of how slow any single
  subscriber is, and an overflowing subscriber's fate never touches any
  other subscriber or the writer.
  """

  use GenServer

  @default_backlog_limit 500
  @default_mailbox_limit 1_000

  @type watch_ref :: reference()
  @type gvk :: String.t()
  @type namespace :: String.t()
  @type resource_version :: String.t()

  @type event :: %{
          required(:type) => :added | :modified | :deleted,
          required(:gvk) => gvk(),
          required(:namespace) => namespace(),
          required(:resource_version) => resource_version(),
          required(:object) => map()
        }

  defmodule Subscriber do
    @moduledoc false
    @enforce_keys [:pid, :gvk, :namespace, :last_delivered_rv, :mailbox_limit]
    defstruct [:pid, :gvk, :namespace, :last_delivered_rv, :mailbox_limit]
  end

  ## Client API

  @doc """
  Starts a WatchHub. Options:

    * `:name` — optional GenServer name/via-tuple
    * `:backlog_limit` — max events retained per gvk (default #{@default_backlog_limit})
    * `:mailbox_limit` — max outstanding messages before a subscriber is
      terminated for overflow (default #{@default_mailbox_limit})
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Publishes a single write event. Appends it to the gvk's backlog and
  dispatches it to every subscriber currently scoped to (gvk, namespace).

  Synchronous: returns only after every currently-registered subscriber has
  either received the event or been terminated for overflow, so a caller
  that commits a write and then calls `notify/2` can be sure the
  corresponding watch event has been (attempted to be) delivered before
  returning a response to its own caller. This does NOT wait on any
  subscriber actually consuming its mailbox — `Kernel.send/2` is
  non-blocking, so a slow subscriber cannot slow this call or the writer
  down.
  """
  @spec notify(GenServer.server(), event()) :: :ok
  def notify(hub, %{} = event) do
    GenServer.call(hub, {:notify, normalize_event(event)})
  end

  @doc """
  Subscribes the calling process to a (gvk, namespace) watch scope, starting
  after `from_resource_version`.

  * `from_resource_version` of `""` or `nil` means "start now" — no backlog
    replay, only events written after this call.
  * `from_resource_version` of `"0"` means "replay everything currently
    retained" — never rejected as stale.
  * Any other `from_resource_version` older than the oldest event still
    retained in the backlog for `gvk` is rejected with `{:error, :gone}` —
    the caller must relist instead of guessing at a gap.
  * `namespace` of `""` or `nil` scopes the watch to all namespaces for that
    gvk.

  On success, the calling process immediately receives (synchronously
  before this call returns) any backlog events newer than
  `from_resource_version` as `{:watch_event, watch_ref, event}` messages,
  and will keep receiving them for every future matching `notify/2` until
  `unsubscribe/2` is called or the watch is terminated for overflow (which
  arrives as `{:watch_terminated, watch_ref, :overflow}`).
  """
  @spec subscribe(GenServer.server(), %{
          required(:gvk) => gvk(),
          required(:namespace) => namespace(),
          required(:from_resource_version) => resource_version() | nil
        }) :: {:ok, watch_ref()} | {:error, :gone}
  def subscribe(hub, %{gvk: gvk, namespace: namespace, from_resource_version: from_rv}) do
    GenServer.call(hub, {:subscribe, self(), gvk, namespace, from_rv})
  end

  @spec unsubscribe(GenServer.server(), watch_ref()) :: :ok
  def unsubscribe(hub, watch_ref) do
    GenServer.call(hub, {:unsubscribe, watch_ref})
  end

  ## Server callbacks

  @impl GenServer
  def init(opts) do
    state = %{
      backlog: %{},
      backlog_limit: Keyword.get(opts, :backlog_limit, @default_backlog_limit),
      mailbox_limit: Keyword.get(opts, :mailbox_limit, @default_mailbox_limit),
      subscribers: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:notify, event}, _from, state) do
    state =
      state
      |> append_to_backlog(event)
      |> dispatch_to_subscribers(event)

    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid, gvk, namespace, from_rv}, _from, state) do
    namespace = normalize_namespace(namespace)

    case replay(state, gvk, namespace, from_rv) do
      {:error, :gone} ->
        {:reply, {:error, :gone}, state}

      {:ok, backlog_events} ->
        watch_ref = make_ref()
        Enum.each(backlog_events, &send(pid, {:watch_event, watch_ref, &1}))

        last_rv =
          case List.last(backlog_events) do
            nil -> normalize_from_rv(from_rv)
            event -> event.resource_version
          end

        subscriber = %Subscriber{
          pid: pid,
          gvk: gvk,
          namespace: namespace,
          last_delivered_rv: last_rv,
          mailbox_limit: state.mailbox_limit
        }

        state = put_in(state, [:subscribers, watch_ref], subscriber)
        {:reply, {:ok, watch_ref}, state}
    end
  end

  def handle_call({:unsubscribe, watch_ref}, _from, state) do
    {_removed, subscribers} = Map.pop(state.subscribers, watch_ref)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  ## Internal — event normalization

  defp normalize_event(event) do
    event
    |> Map.take([:type, :gvk, :namespace, :resource_version, :object])
    |> Map.update!(:resource_version, &to_string/1)
  end

  defp normalize_namespace(nil), do: ""
  defp normalize_namespace(ns), do: ns

  defp normalize_from_rv(nil), do: ""
  defp normalize_from_rv(rv), do: rv

  ## Internal — backlog

  defp append_to_backlog(state, event) do
    gvk_backlog = Map.get(state.backlog, event.gvk, [])
    updated = Enum.take(gvk_backlog ++ [event], -state.backlog_limit)
    %{state | backlog: Map.put(state.backlog, event.gvk, updated)}
  end

  ## Internal — replay / gone detection

  defp replay(state, gvk, namespace, from_rv) do
    gvk_backlog = Map.get(state.backlog, gvk, [])

    cond do
      from_rv in [nil, ""] ->
        {:ok, []}

      from_rv == "0" ->
        {:ok, Enum.filter(gvk_backlog, &namespace_match?(&1, namespace))}

      gvk_backlog == [] ->
        # Nothing retained yet for this gvk — there is no gap to prove,
        # since nothing has ever been evicted. Accept and subscribe live.
        {:ok, []}

      true ->
        oldest_rv = List.first(gvk_backlog).resource_version

        if rv_lt?(from_rv, oldest_rv) do
          {:error, :gone}
        else
          {:ok,
           gvk_backlog
           |> Enum.filter(&namespace_match?(&1, namespace))
           |> Enum.filter(&rv_lt?(from_rv, &1.resource_version))}
        end
    end
  end

  defp namespace_match?(_event, ns) when ns in [nil, ""], do: true
  defp namespace_match?(event, ns), do: event.namespace == ns

  defp rv_lt?(a, b), do: rv_to_comparable(a) < rv_to_comparable(b)

  defp rv_to_comparable(rv) do
    case Integer.parse(rv) do
      {int, ""} -> int
      _ -> rv
    end
  end

  ## Internal — live dispatch

  defp dispatch_to_subscribers(state, event) do
    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {watch_ref, sub}, acc ->
        cond do
          not scope_match?(sub, event) ->
            Map.put(acc, watch_ref, sub)

          overflowing?(sub) ->
            send(sub.pid, {:watch_terminated, watch_ref, :overflow})
            acc

          true ->
            send(sub.pid, {:watch_event, watch_ref, event})
            Map.put(acc, watch_ref, %{sub | last_delivered_rv: event.resource_version})
        end
      end)

    %{state | subscribers: subscribers}
  end

  defp scope_match?(sub, event) do
    sub.gvk == event.gvk and namespace_match?(event, sub.namespace)
  end

  defp overflowing?(sub) do
    case Process.info(sub.pid, :message_queue_len) do
      {:message_queue_len, len} -> len >= sub.mailbox_limit
      # Subscriber process is dead: treat as overflow so it is reaped from
      # `subscribers` rather than accumulating dead entries forever.
      nil -> true
    end
  end
end
