defmodule CrestCiContract.RunnerJobPhase do
  @moduledoc """
  `RunnerJobPhase` is the closed enumeration of states a `RunnerJob` custom
  resource passes through as gateway replicas and the controller arbitrate
  ownership of a single unit of work: `Queued`, `Leased`, `Acquired`,
  `Completed`, `Abandoned`.

  It is a pure value object: an atom drawn from a fixed set, with pure
  conversion functions to/from the capitalized string representation used on
  the Kubernetes JSON wire (e.g. inside `RunnerJobStatus.phase`), plus a pure
  transition table that is the single source of truth for which phase
  changes are legal and who may perform them.

  The phase machine has exactly these legal edges:

    * `Queued -> Leased` — a gateway replica wins the resourceVersion CAS
      race and leases the job to a runner.
    * `Leased -> Acquired` — the runner acknowledges the lease before it
      expires.
    * `Leased -> Queued` — the lease expires before acknowledgement;
      **controller-only** (the sweeper reclaims it, never the gateway).
    * `Acquired -> Completed` — the runner finishes the job.
    * `Leased -> Abandoned` / `Acquired -> Abandoned` — **controller-only**;
      the sweeper gives up on an expired, unacknowledged, or orphaned job.

  No value outside the closed set is ever valid, and no transition outside
  this table is ever legal — `legal_transition?/3` and `transition/3` are the
  only gates callers should use to change a `RunnerJobStatus.phase`. Actor
  authorization (`:controller` vs `:gateway`) is part of the transition
  table itself, not left to callers to enforce ad hoc, so the sweeper-only
  edges (`Leased -> Queued` and `{Leased, Acquired} -> Abandoned`) can never
  be silently taken by a gateway replica.
  """

  @type t :: :queued | :leased | :acquired | :completed | :abandoned

  @typedoc """
  Which side of the controller/gateway split is attempting the transition.
  Some edges (lease-expiry reclamation, abandonment) are reserved for the
  controller sweeper so the phase machine stays auditable to a single owner
  per transition.
  """
  @type actor :: :controller | :gateway

  @wire_by_atom %{
    queued: "Queued",
    leased: "Leased",
    acquired: "Acquired",
    completed: "Completed",
    abandoned: "Abandoned"
  }

  @atom_by_wire Map.new(@wire_by_atom, fn {atom, wire} -> {wire, atom} end)

  @values Map.keys(@wire_by_atom)

  # {from, to} => set of actors permitted to perform the transition.
  # `nil` in the actor set position means "any actor" (both :controller and
  # :gateway are permitted); an explicit list restricts to those actors only.
  @transitions %{
    {:queued, :leased} => :any,
    {:leased, :acquired} => :any,
    {:leased, :queued} => [:controller],
    {:acquired, :completed} => :any,
    {:leased, :abandoned} => [:controller],
    {:acquired, :abandoned} => [:controller]
  }

  @doc "All valid `RunnerJobPhase` values, as atoms."
  @spec values() :: [t()]
  def values, do: @values

  @doc "True when `value` is one of the closed set of `RunnerJobPhase` atoms."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @values

  @doc """
  Renders a `RunnerJobPhase` atom to its Kubernetes wire string
  (e.g. `:acquired` -> `"Acquired"`).
  """
  @spec to_wire(t()) :: String.t()
  def to_wire(phase) when phase in @values, do: Map.fetch!(@wire_by_atom, phase)

  @doc """
  Parses a Kubernetes wire string into a `RunnerJobPhase` atom. Returns
  `{:error, :invalid_runner_job_phase}` for any value outside the closed
  enum, so out-of-enum data is rejected rather than silently coerced.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_runner_job_phase}
  def from_wire(wire) when is_binary(wire) do
    case Map.fetch(@atom_by_wire, wire) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_runner_job_phase}
    end
  end

  def from_wire(_other), do: {:error, :invalid_runner_job_phase}

  @doc """
  True when `from -> to` is one of the declared legal edges *and* `actor` is
  permitted to perform it.

  `Leased -> Queued` (lease expiry) and `{Leased, Acquired} -> Abandoned`
  are controller-only: a `:gateway` actor is refused even though the edge
  itself exists, because only the controller sweeper may reclaim or abandon
  a job.
  """
  @spec legal_transition?(t(), t(), actor()) :: boolean()
  def legal_transition?(from, to, actor)
      when from in @values and to in @values and actor in [:controller, :gateway] do
    case Map.fetch(@transitions, {from, to}) do
      {:ok, :any} -> true
      {:ok, allowed_actors} when is_list(allowed_actors) -> actor in allowed_actors
      :error -> false
    end
  end

  def legal_transition?(_from, _to, _actor), do: false

  @doc """
  Attempts the `from -> to` transition on behalf of `actor`. Returns
  `{:ok, to}` when the edge is legal for that actor, `{:error,
  :illegal_transition}` otherwise (either the edge doesn't exist at all, or
  it exists but is reserved for the other actor).
  """
  @spec transition(t(), t(), actor()) :: {:ok, t()} | {:error, :illegal_transition}
  def transition(from, to, actor) do
    if legal_transition?(from, to, actor) do
      {:ok, to}
    else
      {:error, :illegal_transition}
    end
  end
end
