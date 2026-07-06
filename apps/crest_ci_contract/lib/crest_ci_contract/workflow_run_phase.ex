defmodule CrestCiContract.WorkflowRunPhase do
  @moduledoc """
  `WorkflowRunPhase` is the closed enumeration of states a `WorkflowRun`
  aggregate passes through: `Pending`, `Queued`, `Running`, `Succeeded`,
  `Failed`, `Cancelled`.

  It is a pure value object: an atom drawn from a fixed set, with pure
  conversion functions to/from the capitalized string representation used on
  the Kubernetes JSON wire (e.g. inside `WorkflowRunStatus.phase`). There is
  no mutable state and no I/O here.

  `WorkflowRunStatus.phase` is itself a pure derivation of the aggregate
  `WorkflowRunStatus.jobs` phases (owned by the reconciler, not this value
  object) — this module only guards the shape and the transition legality
  of the phase value once derived.

  The one hard invariant this module enforces: `Succeeded`, `Failed`, and
  `Cancelled` are terminal (absorbing) phases. Once a `WorkflowRun` reaches
  one of them it never transitions to any other phase — the controller must
  treat a terminal phase as a fixed point of reconciliation, never
  overwriting it in response to a later (possibly reordered or replayed)
  event. `transition_allowed?/2` is the single gate callers should use
  before writing a new phase over an existing one.

  No value outside the declared set is ever valid; `from_wire/1` and
  `valid?/1` are the only gates callers should use to admit external data.
  """

  @type t :: :pending | :queued | :running | :succeeded | :failed | :cancelled

  @wire_by_atom %{
    pending: "Pending",
    queued: "Queued",
    running: "Running",
    succeeded: "Succeeded",
    failed: "Failed",
    cancelled: "Cancelled"
  }

  @atom_by_wire Map.new(@wire_by_atom, fn {atom, wire} -> {wire, atom} end)

  @values Map.keys(@wire_by_atom)

  @terminal_values [:succeeded, :failed, :cancelled]

  @doc "All valid `WorkflowRunPhase` values, as atoms."
  @spec values() :: [t()]
  def values, do: @values

  @doc "True when `value` is one of the closed set of `WorkflowRunPhase` atoms."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @values

  @doc """
  True when `phase` is a terminal (absorbing) phase: `:succeeded`, `:failed`,
  or `:cancelled`.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(phase) when phase in @values, do: phase in @terminal_values

  @doc """
  True when transitioning `from` -> `to` is legal.

  The only hard rule: once `from` is a terminal phase, the sole legal
  transition is to itself (i.e. no transition at all). A terminal phase
  never transitions to any other phase. Transitions originating from a
  non-terminal phase are otherwise unconstrained by this value object —
  legality of the *forward* progression (e.g. `:pending` before `:queued`)
  is a concern of the reconciler that derives `WorkflowRunStatus.phase` from
  job phases, not of this closed-enum guard.
  """
  @spec transition_allowed?(t(), t()) :: boolean()
  def transition_allowed?(from, to) when from in @values and to in @values do
    if terminal?(from) do
      to == from
    else
      true
    end
  end

  @doc """
  Renders a `WorkflowRunPhase` atom to its Kubernetes wire string
  (e.g. `:succeeded` -> `"Succeeded"`).
  """
  @spec to_wire(t()) :: String.t()
  def to_wire(phase) when phase in @values, do: Map.fetch!(@wire_by_atom, phase)

  @doc """
  Parses a Kubernetes wire string into a `WorkflowRunPhase` atom. Returns
  `{:error, :invalid_workflow_run_phase}` for any value outside the closed
  enum, so out-of-enum data is rejected rather than silently coerced.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_workflow_run_phase}
  def from_wire(wire) when is_binary(wire) do
    case Map.fetch(@atom_by_wire, wire) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_workflow_run_phase}
    end
  end

  def from_wire(_other), do: {:error, :invalid_workflow_run_phase}
end
