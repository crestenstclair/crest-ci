defmodule CrestCiContract.RunnerJobStatus do
  @moduledoc """
  Lease and acquisition record for a `RunnerJob`, written under the
  `status` subresource and arbitrated by `resourceVersion` compare-and-swap.

  `phase` is drawn from the closed `RunnerJobPhase` enumeration:
  `Queued | Leased | Acquired | Completed | Abandoned`. This module treats
  that enumeration as its own closed set (via `phases/0`) rather than
  depending on a separate `RunnerJobPhase` value object module, so
  `RunnerJobStatus` has exactly one reason to change: the shape of the
  lease/acquisition status record.

  Legal phase transitions (enforced by the controller/gateway reconcilers
  that consume this struct, not by the struct itself, since a value object
  only knows what a valid *value* looks like, not orchestration policy):

    * `Queued -> Leased` (a gateway replica offers the job to a runner)
    * `Leased -> Acquired` (the runner wins the resourceVersion CAS)
    * `Leased -> Queued` (lease expiry, controller sweeper only)
    * `Acquired -> Completed` (the runner reports a terminal result)
    * `{Leased, Acquired} -> Abandoned` (controller sweeper only, on
      expired lease without heartbeat)

  A lost CAS during acquisition means another actor won; the loser moves
  on rather than retrying against a stale `resourceVersion`. An expired
  lease transitions to `Abandoned` via the controller sweeper — never
  silently back to `Queued` by the gateway.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1`, and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls.
  """

  @phases [:queued, :leased, :acquired, :completed, :abandoned]

  @wire_by_phase %{
    queued: "Queued",
    leased: "Leased",
    acquired: "Acquired",
    completed: "Completed",
    abandoned: "Abandoned"
  }

  @phase_by_wire Map.new(@wire_by_phase, fn {phase, wire} -> {wire, phase} end)

  @type phase :: :queued | :leased | :acquired | :completed | :abandoned

  @type t :: %__MODULE__{
          acquired_at: String.t(),
          lease_expires_at: String.t(),
          leased_by: String.t(),
          phase: phase(),
          result: String.t()
        }

  @enforce_keys [:phase]
  defstruct acquired_at: "",
            lease_expires_at: "",
            leased_by: "",
            phase: :queued,
            result: ""

  @doc "The closed set of legal `phase` values, in declaration order."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  Builds a new `RunnerJobStatus` from field values (atom keys, `phase` as
  an atom), rejecting any `phase` outside the closed enumeration.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_phase, term()}}
  def new(fields) when is_map(fields) do
    phase = Map.get(fields, :phase, :queued)

    if phase in @phases do
      {:ok,
       %__MODULE__{
         acquired_at: Map.get(fields, :acquired_at, ""),
         lease_expires_at: Map.get(fields, :lease_expires_at, ""),
         leased_by: Map.get(fields, :leased_by, ""),
         phase: phase,
         result: Map.get(fields, :result, "")
       }}
    else
      {:error, {:invalid_phase, phase}}
    end
  end

  @doc """
  Decodes a `RunnerJobStatus` from its Kubernetes JSON wire shape: a map
  with camelCase string keys and `"phase"` as one of the declared enum
  strings (e.g. `"Acquired"`). Returns `{:error, {:invalid_phase, term}}`
  for any phase value outside the closed enumeration, so no out-of-enum
  phase is ever observed downstream.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, {:invalid_phase, term()}}
  def from_wire(%{} = wire) do
    with {:ok, phase} <- parse_phase(Map.get(wire, "phase", "Queued")) do
      new(%{
        acquired_at: Map.get(wire, "acquiredAt", ""),
        lease_expires_at: Map.get(wire, "leaseExpiresAt", ""),
        leased_by: Map.get(wire, "leasedBy", ""),
        phase: phase,
        result: Map.get(wire, "result", "")
      })
    end
  end

  @doc "Encodes a `RunnerJobStatus` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = status) do
    %{
      "acquiredAt" => status.acquired_at,
      "leaseExpiresAt" => status.lease_expires_at,
      "leasedBy" => status.leased_by,
      "phase" => Map.fetch!(@wire_by_phase, status.phase),
      "result" => status.result
    }
  end

  @doc """
  True when `from_phase -> to_phase` is a legal `RunnerJobPhase`
  transition per the phase machine documented above. Identity (no-op)
  transitions are not legal moves — a transition changes phase.
  """
  @spec legal_transition?(phase(), phase()) :: boolean()
  def legal_transition?(:queued, :leased), do: true
  def legal_transition?(:leased, :acquired), do: true
  def legal_transition?(:leased, :queued), do: true
  def legal_transition?(:acquired, :completed), do: true
  def legal_transition?(:leased, :abandoned), do: true
  def legal_transition?(:acquired, :abandoned), do: true
  def legal_transition?(_from, _to), do: false

  @spec parse_phase(term()) :: {:ok, phase()} | {:error, {:invalid_phase, term()}}
  defp parse_phase(wire) do
    case Map.fetch(@phase_by_wire, wire) do
      {:ok, phase} -> {:ok, phase}
      :error -> {:error, {:invalid_phase, wire}}
    end
  end
end

defimpl Jason.Encoder, for: CrestCiContract.RunnerJobStatus do
  def encode(status, opts) do
    status
    |> CrestCiContract.RunnerJobStatus.to_wire()
    |> Jason.Encode.map(opts)
  end
end
