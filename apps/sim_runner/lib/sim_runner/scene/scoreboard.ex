defmodule SimRunner.Scene.Scoreboard do
  @moduledoc """
  The final verdict of a demo scene's verification pass: nine counters, every
  one of them computed from authoritative state observed after the scenario
  has run to completion (custom-resource status, log-chunk compaction
  results, cache/artifact round-trips, controller/gateway restart
  bookkeeping) — never from an in-process counter incremented as side effects
  happen, exactly like `SimRunner.Demo.ResultsOrchestrator`'s `metrics()` and
  `SimRunner.Demo.LogVerifier`'s gap detection.

  This module is a pure value object: it holds data and validates it, and has
  no knowledge of terminals, ANSI codes, or `IO.puts/1`. A scene's renderer
  (a separate collaborator, injected wherever it is needed rather than
  constructed here) is responsible for turning a `Scoreboard` into either a
  redrawn TTY frame or plain append-only narration lines — that is a
  presentation concern, not this value object's reason to change.

  Serializes to/from the same camelCase wire-shape convention used by every
  `CrestCiContract` value object, so a `Scoreboard` can be logged, diffed, or
  round-tripped through JSON identically to a custom resource's status.
  """

  @fields [
    :archive_gaps,
    :cache_hits,
    :controller_failover_gap_ms,
    :controller_failovers,
    :duplicate_acquisitions,
    :gateway_failovers,
    :rehomed_runners,
    :runs_failed,
    :runs_succeeded
  ]

  @wire_by_field %{
    archive_gaps: "archiveGaps",
    cache_hits: "cacheHits",
    controller_failover_gap_ms: "controllerFailoverGapMs",
    controller_failovers: "controllerFailovers",
    duplicate_acquisitions: "duplicateAcquisitions",
    gateway_failovers: "gatewayFailovers",
    rehomed_runners: "rehomedRunners",
    runs_failed: "runsFailed",
    runs_succeeded: "runsSucceeded"
  }

  @field_by_wire Map.new(@wire_by_field, fn {field, wire} -> {wire, field} end)

  @type t :: %__MODULE__{
          archive_gaps: non_neg_integer(),
          cache_hits: non_neg_integer(),
          controller_failover_gap_ms: non_neg_integer(),
          controller_failovers: non_neg_integer(),
          duplicate_acquisitions: non_neg_integer(),
          gateway_failovers: non_neg_integer(),
          rehomed_runners: non_neg_integer(),
          runs_failed: non_neg_integer(),
          runs_succeeded: non_neg_integer()
        }

  defstruct archive_gaps: 0,
            cache_hits: 0,
            controller_failover_gap_ms: 0,
            controller_failovers: 0,
            duplicate_acquisitions: 0,
            gateway_failovers: 0,
            rehomed_runners: 0,
            runs_failed: 0,
            runs_succeeded: 0

  @doc "The closed set of counter fields, in declaration order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Builds a new `Scoreboard` from field values (atom keys, same names as the
  struct). Every field defaults to `0` when absent, and every present field
  must be a non-negative integer — a negative counter or duration can never
  be authoritative-state fact, so it is rejected rather than silently
  clamped or coerced.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_field, atom(), term()}}
  def new(fields) when is_map(fields) do
    values = Map.new(@fields, fn field -> {field, Map.get(fields, field, 0)} end)

    case first_invalid(values) do
      nil -> {:ok, struct(__MODULE__, values)}
      {field, value} -> {:error, {:invalid_field, field, value}}
    end
  end

  @doc """
  Decodes a `Scoreboard` from its JSON wire shape: a map with the camelCase
  string keys declared on this value object. Unknown keys are ignored;
  missing keys default to `0`, same as `new/1`.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, {:invalid_field, atom(), term()}}
  def from_wire(%{} = wire) do
    fields =
      Map.new(@field_by_wire, fn {wire_key, field} -> {field, Map.get(wire, wire_key, 0)} end)

    new(fields)
  end

  @doc "Encodes a `Scoreboard` into its camelCase JSON wire shape."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = scoreboard) do
    Map.new(@wire_by_field, fn {field, wire_key} -> {wire_key, Map.fetch!(scoreboard, field)} end)
  end

  @spec first_invalid(%{atom() => term()}) :: {atom(), term()} | nil
  defp first_invalid(values) do
    Enum.find_value(@fields, fn field ->
      value = Map.fetch!(values, field)
      if is_integer(value) and value >= 0, do: nil, else: {field, value}
    end)
  end
end

defimpl Jason.Encoder, for: SimRunner.Scene.Scoreboard do
  def encode(scoreboard, opts) do
    scoreboard
    |> SimRunner.Scene.Scoreboard.to_wire()
    |> Jason.Encode.map(opts)
  end
end
