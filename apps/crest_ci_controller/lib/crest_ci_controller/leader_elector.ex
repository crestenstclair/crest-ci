defmodule CrestCiController.LeaderElector do
  @moduledoc """
  Coordination-Lease-based leader election for controller replicas.

  At most one controller replica reconciles at a time, guarded by a
  `coordination.k8s.io` Lease object read/written exclusively through
  `CrestCiContract.KubeClient` — the only interface between controller and
  gateway/cluster state. This process holds no authoritative truth itself:
  every field it needs to decide "am I leader?" is re-derived from the
  Lease object on every tick, so a crash and restart converges to the
  correct answer without any special recovery path (G3 statelessness).

  A `LeaderElector` instance is `start_link/3`-able with an explicit
  `kube_conn`, `identity`, and `election_timings` map — nothing reads
  global application config, so tests boot several instances against one
  shared mock Kubernetes API server and race them against each other.

  `kube_conn` is `{adapter_module, adapter_conn}`: the concrete
  `CrestCiContract.KubeClient`-behaviour implementation is injected by the
  caller, never hardcoded here (Dependency Inversion) — this module is
  substitutable across the real Req-based adapter, the mock-k8s HTTP
  adapter, or any test double, without a single line changing.

  ## Election protocol

  On an interval, the process:

    1. `get`s the Lease. If absent, `create`s it naming itself holder.
       A lost creation race (`{:error, :already_exists}`) means another
       replica won; this instance stays a non-leader and retries.
    2. If present and held by this identity, renews it (bumps
       `renewTime`) via `update`, CAS'd on the last-read
       `resourceVersion`.
    3. If present, held by another identity, and NOT expired
       (`renewTime + leaseDurationSeconds` is in the past), stays a
       non-leader and retries later.
    4. If present and expired, attempts to take over via a CAS'd
       `update` (bumping `leaseTransitions`). A lost CAS
       (`{:error, :conflict}`) means another replica won the race first;
       this instance stays a non-leader.

  Every `update`/`create` outcome that is not an unambiguous win leaves
  this instance a non-leader — arbitration is entirely the store's
  optimistic-concurrency check, never a local guess.

  Subscribers registered via `subscribe/2` receive exactly one message per
  observed transition: `{:leader_acquired, identity}` when this instance
  starts holding the lease, `{:leader_lost, identity}` when it stops
  (including a clean, voluntary step-down on shutdown, which releases the
  Lease immediately so another instance need not wait out the full lease
  duration). Because the first election attempt is kicked off
  asynchronously from `init/1` (never blocking `start_link/3`), a
  subscriber calling `subscribe/2` after that first attempt already
  resolved is caught up immediately with the current status rather than
  missing the transition.
  """

  use GenServer

  alias CrestCiContract.LeaseSpec

  @gvk {"coordination.k8s.io", "v1", "Lease"}
  @default_namespace "crest-ci-system"
  @default_lease_name "crest-ci-controller"

  @typedoc """
  `{adapter_module, adapter_conn}` — `adapter_module` implements the
  `CrestCiContract.KubeClient` behaviour; `adapter_conn` is whatever opaque
  handle that module's callbacks expect as their first argument.
  """
  @type kube_conn :: {module(), term()}

  @typedoc "Opaque identity string this instance advertises as Lease holder."
  @type identity :: String.t()

  @typedoc """
  Election timing/configuration knobs.

  Required:
    * `:lease_duration_seconds` — how long a Lease is valid after its last
      renewal before it is considered expired and takeover-eligible
    * `:renew_interval_ms` — how often a leader renews its held Lease;
      must be comfortably inside `lease_duration_seconds * 1000` so a live
      leader's Lease never lapses
    * `:retry_interval_ms` — how often a non-leader re-attempts election

  Optional (default to a fixed shared Lease identity so multiple
  instances in the same test/deployment contend for the same object):
    * `:namespace` — Lease namespace (default `"crest-ci-system"`)
    * `:lease_name` — Lease name (default `"crest-ci-controller"`)
  """
  @type election_timings :: %{
          required(:lease_duration_seconds) => pos_integer(),
          required(:renew_interval_ms) => pos_integer(),
          required(:retry_interval_ms) => pos_integer(),
          optional(:namespace) => String.t(),
          optional(:lease_name) => String.t()
        }

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :kube_conn,
      :identity,
      :namespace,
      :lease_name,
      :lease_duration_seconds,
      :renew_interval_ms,
      :retry_interval_ms
    ]
    defstruct [
      :kube_conn,
      :identity,
      :namespace,
      :lease_name,
      :lease_duration_seconds,
      :renew_interval_ms,
      :retry_interval_ms,
      :resource_version,
      :lease_transitions,
      is_leader: false,
      subscribers: MapSet.new()
    ]
  end

  # -- Client API ----------------------------------------------------------

  @doc """
  Starts a `LeaderElector`. Contends for a shared coordination Lease using
  `identity` as this instance's holder identity. Never auto-started by any
  application `mod:` entry — callers (tests, demo harnesses, the eventual
  controller supervision tree) start instances explicitly.
  """
  @spec start_link(kube_conn(), identity(), election_timings()) :: {:ok, pid()}
  def start_link(kube_conn, identity, election_timings) do
    GenServer.start_link(__MODULE__, {kube_conn, identity, election_timings})
  end

  @doc "Returns whether `pid` currently believes it holds the Lease."
  @spec leader?(pid()) :: boolean()
  def leader?(pid) do
    GenServer.call(pid, :leader?)
  end

  @doc """
  Registers `subscriber` to receive `{:leader_acquired, identity}` /
  `{:leader_lost, identity}` messages on every future leadership
  transition observed by `pid`. `subscriber` is monitored; a dead
  subscriber is dropped without error.

  If `pid` already holds the Lease at subscribe time, `subscriber` is
  immediately sent `{:leader_acquired, identity}` so a subscriber that
  registers after the first election has already resolved never misses
  the current status.
  """
  @spec subscribe(pid(), pid()) :: :ok
  def subscribe(pid, subscriber) do
    GenServer.call(pid, {:subscribe, subscriber})
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init({kube_conn, identity, election_timings}) do
    state = %State{
      kube_conn: kube_conn,
      identity: identity,
      namespace: Map.get(election_timings, :namespace, @default_namespace),
      lease_name: Map.get(election_timings, :lease_name, @default_lease_name),
      lease_duration_seconds: Map.fetch!(election_timings, :lease_duration_seconds),
      renew_interval_ms: Map.fetch!(election_timings, :renew_interval_ms),
      retry_interval_ms: Map.fetch!(election_timings, :retry_interval_ms)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:leader?, _from, state) do
    {:reply, state.is_leader, state}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    Process.monitor(subscriber)
    if state.is_leader, do: send(subscriber, {:leader_acquired, state.identity})
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, subscriber)}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, attempt_election(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def terminate(_reason, %State{is_leader: true} = state) do
    notify_subscribers(state, {:leader_lost, state.identity})
    step_down(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Election protocol -----------------------------------------------------

  defp attempt_election(state) do
    case kube_get(state, state.lease_name) do
      {:error, :not_found} -> try_create(state)
      {:ok, object} -> handle_existing_lease(state, object)
      {:error, _transport_error} -> schedule_retry(state)
    end
  end

  defp try_create(state) do
    now = iso_now()

    case LeaseSpec.new(now, state.identity, state.lease_duration_seconds, 0, now) do
      {:ok, spec} ->
        object = build_object(state, spec, nil)

        case kube_create(state, object) do
          {:ok, created} ->
            transition_to_leader(state, resource_version_of(created), 0)

          {:error, :already_exists} ->
            transition_to_non_leader(state)

          {:error, _transport_error} ->
            schedule_retry(state)
        end

      {:error, :invalid_lease_spec} ->
        schedule_retry(state)
    end
  end

  defp handle_existing_lease(state, object) do
    case LeaseSpec.from_wire(Map.get(object, "spec", %{})) do
      {:ok, spec} ->
        rv = resource_version_of(object)

        cond do
          spec.holder_identity == state.identity ->
            renew(state, object, spec, rv)

          lease_expired?(spec) ->
            take_over(state, object, spec, rv)

          true ->
            transition_to_non_leader(state)
        end

      {:error, :invalid_lease_spec} ->
        schedule_retry(state)
    end
  end

  defp renew(state, _object, spec, rv) do
    now = iso_now()

    case LeaseSpec.new(
           spec.acquire_time,
           state.identity,
           state.lease_duration_seconds,
           spec.lease_transitions,
           now
         ) do
      {:ok, new_spec} ->
        updated = build_object(state, new_spec, rv)

        case kube_update(state, updated) do
          {:ok, result} ->
            transition_to_leader(state, resource_version_of(result), spec.lease_transitions)

          {:error, :conflict} ->
            transition_to_non_leader(state)

          {:error, _transport_error} ->
            schedule_retry(state)
        end

      {:error, :invalid_lease_spec} ->
        schedule_retry(state)
    end
  end

  defp take_over(state, _object, spec, rv) do
    now = iso_now()
    next_transitions = spec.lease_transitions + 1

    case LeaseSpec.new(now, state.identity, state.lease_duration_seconds, next_transitions, now) do
      {:ok, new_spec} ->
        updated = build_object(state, new_spec, rv)

        case kube_update(state, updated) do
          {:ok, result} ->
            transition_to_leader(state, resource_version_of(result), next_transitions)

          {:error, :conflict} ->
            transition_to_non_leader(state)

          {:error, _transport_error} ->
            schedule_retry(state)
        end

      {:error, :invalid_lease_spec} ->
        schedule_retry(state)
    end
  end

  defp step_down(state) do
    case kube_delete(state, state.lease_name) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  # -- State transitions ------------------------------------------------------

  defp transition_to_leader(state, resource_version, lease_transitions) do
    was_leader = state.is_leader

    new_state = %{
      state
      | is_leader: true,
        resource_version: resource_version,
        lease_transitions: lease_transitions
    }

    unless was_leader, do: notify_subscribers(new_state, {:leader_acquired, state.identity})
    schedule_renew(new_state)
  end

  defp transition_to_non_leader(state) do
    was_leader = state.is_leader
    new_state = %{state | is_leader: false, resource_version: nil}
    if was_leader, do: notify_subscribers(new_state, {:leader_lost, state.identity})
    schedule_retry(new_state)
  end

  defp notify_subscribers(state, message) do
    Enum.each(state.subscribers, &send(&1, message))
  end

  defp schedule_renew(state) do
    Process.send_after(self(), :tick, state.renew_interval_ms)
    state
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :tick, state.retry_interval_ms)
    state
  end

  # -- Injected KubeClient adapter dispatch ------------------------------
  #
  # Every call resolves the concrete adapter module from the injected
  # `kube_conn` (Dependency Inversion — this module never hardcodes an
  # adapter) and delegates straight through to it.

  defp kube_get(%State{kube_conn: {module, conn}, namespace: namespace}, name),
    do: module.get(conn, @gvk, namespace, name)

  defp kube_create(%State{kube_conn: {module, conn}, namespace: namespace}, object),
    do: module.create(conn, @gvk, namespace, object)

  defp kube_update(%State{kube_conn: {module, conn}, namespace: namespace}, object),
    do: module.update(conn, @gvk, namespace, object)

  defp kube_delete(%State{kube_conn: {module, conn}, namespace: namespace}, name),
    do: module.delete(conn, @gvk, namespace, name)

  # -- Helpers ------------------------------------------------------------

  defp lease_expired?(spec) do
    case DateTime.from_iso8601(spec.renew_time) do
      {:ok, renew_time, _offset} ->
        expiry = DateTime.add(renew_time, spec.lease_duration_seconds, :second)
        DateTime.compare(DateTime.utc_now(), expiry) != :lt

      {:error, _reason} ->
        true
    end
  end

  defp build_object(state, spec, resource_version) do
    metadata =
      %{"name" => state.lease_name, "namespace" => state.namespace}
      |> maybe_put_resource_version(resource_version)

    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => metadata,
      "spec" => LeaseSpec.to_wire(spec)
    }
  end

  defp maybe_put_resource_version(metadata, nil), do: metadata

  defp maybe_put_resource_version(metadata, resource_version),
    do: Map.put(metadata, "resourceVersion", resource_version)

  defp resource_version_of(object), do: get_in(object, ["metadata", "resourceVersion"])

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
