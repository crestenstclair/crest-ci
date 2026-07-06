defmodule CrestCiContract.LeaseSpec do
  @moduledoc """
  `LeaseSpec` mirrors the `coordination.k8s.io/v1` Lease spec used for
  controller leader election: at most one controller replica reconciles at
  a time, guarded by this coordination Lease (see the "at most one
  controller replica reconciles at a time" architectural invariant).
  Non-leaders keep warm caches and take over within
  `lease_duration_seconds` plus a renew margin.

  Fields:
    * `acquire_time` — RFC3339 timestamp string of when the current holder
      most recently acquired the lease
    * `holder_identity` — opaque identity string of the current holder
    * `lease_duration_seconds` — duration, in seconds, that a lease is
      valid for after `renew_time`
    * `lease_transitions` — count of times the lease has changed holders
    * `renew_time` — RFC3339 timestamp string of the holder's most recent
      renewal

  Pure value object: a plain struct with (de)serialization to/from the
  Kubernetes JSON wire shape (camelCase keys) as plain maps, ready for
  `Jason.encode!/1` / produced by `Jason.decode!/1`. There is no I/O and no
  process state here — reading and writing the Lease resource itself is
  the job of a `port.Contract.KubeClient` adapter, not this module.

  Well-formedness, enforced by `new/5` (and therefore by `from_wire/1`,
  which delegates to it):
    * `acquire_time` / `renew_time` must be non-empty, RFC3339-parseable
      timestamp strings
    * `holder_identity` must be a non-empty string
    * `lease_duration_seconds` must be a positive integer (a zero or
      negative lease duration can never be validly held)
    * `lease_transitions` must be a non-negative integer (a transition
      count cannot go below zero)
  """

  @enforce_keys [
    :acquire_time,
    :holder_identity,
    :lease_duration_seconds,
    :lease_transitions,
    :renew_time
  ]
  defstruct [
    :acquire_time,
    :holder_identity,
    :lease_duration_seconds,
    :lease_transitions,
    :renew_time
  ]

  @type t :: %__MODULE__{
          acquire_time: String.t(),
          holder_identity: String.t(),
          lease_duration_seconds: integer(),
          lease_transitions: integer(),
          renew_time: String.t()
        }

  @doc """
  Builds a `LeaseSpec` from field values, validating well-formedness:
  `acquire_time` / `renew_time` must be non-empty RFC3339 timestamp
  strings, `holder_identity` must be a non-empty string,
  `lease_duration_seconds` must be a positive integer, and
  `lease_transitions` must be a non-negative integer. Returns
  `{:error, :invalid_lease_spec}` for anything else, rather than raising.
  """
  @spec new(String.t(), String.t(), integer(), integer(), String.t()) ::
          {:ok, t()} | {:error, :invalid_lease_spec}
  def new(acquire_time, holder_identity, lease_duration_seconds, lease_transitions, renew_time) do
    with {:ok, acquire_time} <- validate_timestamp(acquire_time),
         {:ok, holder_identity} <- validate_identity(holder_identity),
         {:ok, lease_duration_seconds} <- validate_positive_integer(lease_duration_seconds),
         {:ok, lease_transitions} <- validate_non_negative_integer(lease_transitions),
         {:ok, renew_time} <- validate_timestamp(renew_time) do
      {:ok,
       %__MODULE__{
         acquire_time: acquire_time,
         holder_identity: holder_identity,
         lease_duration_seconds: lease_duration_seconds,
         lease_transitions: lease_transitions,
         renew_time: renew_time
       }}
    else
      :error -> {:error, :invalid_lease_spec}
    end
  end

  @doc """
  Renders a `LeaseSpec` to the Kubernetes JSON wire map (camelCase keys),
  suitable for `Jason.encode!/1`.
  """
  @spec to_wire(t()) :: %{String.t() => String.t() | integer()}
  def to_wire(%__MODULE__{} = spec) do
    %{
      "acquireTime" => spec.acquire_time,
      "holderIdentity" => spec.holder_identity,
      "leaseDurationSeconds" => spec.lease_duration_seconds,
      "leaseTransitions" => spec.lease_transitions,
      "renewTime" => spec.renew_time
    }
  end

  @doc """
  Parses a Kubernetes JSON wire map (string-keyed, camelCase, as produced
  by `Jason.decode!/1`) into a `LeaseSpec`. Rejects maps missing any
  required field, with a field of the wrong type, or failing the
  well-formedness rules enforced by `new/5` (non-empty/parseable
  timestamps, non-empty identity, positive duration, non-negative
  transition count), returning `{:error, :invalid_lease_spec}` rather than
  raising — out-of-shape wire data is never silently coerced.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_lease_spec}
  def from_wire(%{} = wire) do
    with {:ok, acquire_time} <- fetch_string(wire, "acquireTime"),
         {:ok, holder_identity} <- fetch_string(wire, "holderIdentity"),
         {:ok, lease_duration_seconds} <- fetch_integer(wire, "leaseDurationSeconds"),
         {:ok, lease_transitions} <- fetch_integer(wire, "leaseTransitions"),
         {:ok, renew_time} <- fetch_string(wire, "renewTime") do
      new(acquire_time, holder_identity, lease_duration_seconds, lease_transitions, renew_time)
    else
      :error -> {:error, :invalid_lease_spec}
    end
  end

  def from_wire(_other), do: {:error, :invalid_lease_spec}

  @wire_keys ~w(acquireTime holderIdentity leaseDurationSeconds leaseTransitions renewTime)

  defp fetch_string(wire, key) when key in @wire_keys do
    case Map.get(wire, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_integer(wire, key) when key in @wire_keys do
    case Map.get(wire, key) do
      value when is_integer(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp validate_timestamp(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp validate_timestamp(_other), do: :error

  defp validate_identity(value) when is_binary(value) and value != "", do: {:ok, value}
  defp validate_identity(_other), do: :error

  defp validate_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_positive_integer(_other), do: :error

  defp validate_non_negative_integer(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp validate_non_negative_integer(_other), do: :error
end
