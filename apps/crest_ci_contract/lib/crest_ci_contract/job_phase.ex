defmodule CrestCiContract.JobPhase do
  @moduledoc """
  `JobPhase` is the closed enumeration of states a single job (a node in a
  `WorkflowRun` plan DAG) passes through: `Waiting`, `Queued`, `Assigned`,
  `Running`, `Succeeded`, `Failed`, `Cancelled`, `Skipped`.

  It is a pure value object: an atom drawn from a fixed set, with pure
  conversion functions to/from the capitalized string representation used on
  the Kubernetes JSON wire (e.g. inside `JobStatus.phase`). There is no
  mutable state and no I/O here — orchestration logic that decides *when* a
  job transitions between phases belongs to the controller/gateway contexts,
  not to this value object.

  No value outside the declared set is ever valid; `from_wire/1` and
  `valid?/1` are the only gates callers should use to admit external data.
  """

  @type t ::
          :waiting
          | :queued
          | :assigned
          | :running
          | :succeeded
          | :failed
          | :cancelled
          | :skipped

  @wire_by_atom %{
    waiting: "Waiting",
    queued: "Queued",
    assigned: "Assigned",
    running: "Running",
    succeeded: "Succeeded",
    failed: "Failed",
    cancelled: "Cancelled",
    skipped: "Skipped"
  }

  @atom_by_wire Map.new(@wire_by_atom, fn {atom, wire} -> {wire, atom} end)

  @values Map.keys(@wire_by_atom)

  @doc "All valid `JobPhase` values, as atoms."
  @spec values() :: [t()]
  def values, do: @values

  @doc "True when `value` is one of the closed set of `JobPhase` atoms."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @values

  @doc """
  Renders a `JobPhase` atom to its Kubernetes wire string
  (e.g. `:succeeded` -> `"Succeeded"`).
  """
  @spec to_wire(t()) :: String.t()
  def to_wire(phase) when phase in @values, do: Map.fetch!(@wire_by_atom, phase)

  @doc """
  Parses a Kubernetes wire string into a `JobPhase` atom. Returns
  `{:error, :invalid_job_phase}` for any value outside the closed enum,
  so out-of-enum data is rejected rather than silently coerced.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_job_phase}
  def from_wire(wire) when is_binary(wire) do
    case Map.fetch(@atom_by_wire, wire) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_job_phase}
    end
  end

  def from_wire(_other), do: {:error, :invalid_job_phase}
end
