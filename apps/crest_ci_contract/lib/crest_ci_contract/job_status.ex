defmodule CrestCiContract.JobStatus do
  @moduledoc """
  Per-job execution record carried inside `WorkflowRunStatus.jobs`, keyed by
  `JobKey`.

  `assignedRunner` and `outputs` are written by the gateway as a runner is
  matched and reports results; `phase`, `queuedAt`, `startedAt`,
  `finishedAt`, and `logChunks` are orchestration fields written by the
  controller. No single writer owns every field, but each field has exactly
  one writer — the struct itself does not enforce who is allowed to write,
  only what a valid value looks like.

  `phase` is drawn from the closed `JobPhase` enumeration:
  `Waiting | Queued | Assigned | Running | Succeeded | Failed | Cancelled |
  Skipped`. This module treats that enumeration as its own closed set (via
  `phases/0`) rather than depending on the `JobPhase` value object module,
  so `JobStatus` has exactly one reason to change: the shape of the
  per-job status record.

  `logChunks` tracks how many log chunks have been ingested for the job.
  Log chunk ingestion is idempotent by `(job, step, chunk sequence)` — a
  duplicate or re-sent chunk after a runner reconnect must be absorbed
  without regressing the count. `update/2` enforces this by clamping
  `logChunks` to `max(current, incoming)` rather than blindly overwriting
  it, so replaying any update sequence (including out-of-order or
  duplicate deliveries) converges to the same, correct count.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1`, and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls.
  """

  @phases [:waiting, :queued, :assigned, :running, :succeeded, :failed, :cancelled, :skipped]

  @wire_by_phase %{
    waiting: "Waiting",
    queued: "Queued",
    assigned: "Assigned",
    running: "Running",
    succeeded: "Succeeded",
    failed: "Failed",
    cancelled: "Cancelled",
    skipped: "Skipped"
  }

  @phase_by_wire Map.new(@wire_by_phase, fn {phase, wire} -> {wire, phase} end)

  @type phase ::
          :waiting
          | :queued
          | :assigned
          | :running
          | :succeeded
          | :failed
          | :cancelled
          | :skipped

  @type t :: %__MODULE__{
          assigned_runner: String.t(),
          finished_at: String.t(),
          log_chunks: non_neg_integer(),
          outputs: %{optional(String.t()) => String.t()},
          phase: phase(),
          queued_at: String.t(),
          started_at: String.t()
        }

  @enforce_keys [:phase]
  defstruct assigned_runner: "",
            finished_at: "",
            log_chunks: 0,
            outputs: %{},
            phase: :waiting,
            queued_at: "",
            started_at: ""

  @doc "The closed set of legal `phase` values, in declaration order."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  Builds a new `JobStatus` from field values (atom keys, `phase` as an
  atom), rejecting any `phase` outside the closed enumeration.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_phase, term()}}
  def new(fields) when is_map(fields) do
    phase = Map.get(fields, :phase, :waiting)

    if phase in @phases do
      {:ok,
       %__MODULE__{
         assigned_runner: Map.get(fields, :assigned_runner, ""),
         finished_at: Map.get(fields, :finished_at, ""),
         log_chunks: Map.get(fields, :log_chunks, 0),
         outputs: Map.get(fields, :outputs, %{}),
         phase: phase,
         queued_at: Map.get(fields, :queued_at, ""),
         started_at: Map.get(fields, :started_at, "")
       }}
    else
      {:error, {:invalid_phase, phase}}
    end
  end

  @doc """
  Applies an incoming set of field updates (same shape as `new/1`'s
  `fields` map) on top of an existing `JobStatus`, producing the merged
  result. Any field not present in `fields` keeps its current value.

  `log_chunks` is the one field that is never blindly overwritten: the
  merged value is `max(current.log_chunks, incoming log_chunks)`. This
  keeps repeated or out-of-order chunk-count updates idempotent — a
  duplicate or stale (lower) `log_chunks` in `fields` cannot regress the
  count, matching the "log chunk ingestion is idempotent" invariant.

  Rejects an incoming `phase` outside the closed enumeration, leaving the
  current struct untouched (the update is rejected as a whole).
  """
  @spec update(t(), map()) :: {:ok, t()} | {:error, {:invalid_phase, term()}}
  def update(%__MODULE__{} = current, fields) when is_map(fields) do
    phase = Map.get(fields, :phase, current.phase)

    if phase in @phases do
      incoming_log_chunks = Map.get(fields, :log_chunks, current.log_chunks)

      {:ok,
       %__MODULE__{
         current
         | assigned_runner: Map.get(fields, :assigned_runner, current.assigned_runner),
           finished_at: Map.get(fields, :finished_at, current.finished_at),
           log_chunks: max(current.log_chunks, incoming_log_chunks),
           outputs: Map.get(fields, :outputs, current.outputs),
           phase: phase,
           queued_at: Map.get(fields, :queued_at, current.queued_at),
           started_at: Map.get(fields, :started_at, current.started_at)
       }}
    else
      {:error, {:invalid_phase, phase}}
    end
  end

  @doc """
  Decodes a `JobStatus` from its Kubernetes JSON wire shape: a map with
  camelCase string keys and `"phase"` as one of the declared enum strings
  (e.g. `"Running"`). Returns `{:error, {:invalid_phase, term}}` for any
  phase value outside the closed enumeration, so no out-of-enum phase is
  ever observed downstream.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, {:invalid_phase, term()}}
  def from_wire(%{} = wire) do
    with {:ok, phase} <- parse_phase(Map.get(wire, "phase", "Waiting")) do
      new(%{
        assigned_runner: Map.get(wire, "assignedRunner", ""),
        finished_at: Map.get(wire, "finishedAt", ""),
        log_chunks: Map.get(wire, "logChunks", 0),
        outputs: Map.get(wire, "outputs", %{}),
        phase: phase,
        queued_at: Map.get(wire, "queuedAt", ""),
        started_at: Map.get(wire, "startedAt", "")
      })
    end
  end

  @doc "Encodes a `JobStatus` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = status) do
    %{
      "assignedRunner" => status.assigned_runner,
      "finishedAt" => status.finished_at,
      "logChunks" => status.log_chunks,
      "outputs" => status.outputs,
      "phase" => Map.fetch!(@wire_by_phase, status.phase),
      "queuedAt" => status.queued_at,
      "startedAt" => status.started_at
    }
  end

  @spec parse_phase(term()) :: {:ok, phase()} | {:error, {:invalid_phase, term()}}
  defp parse_phase(wire) do
    case Map.fetch(@phase_by_wire, wire) do
      {:ok, phase} -> {:ok, phase}
      :error -> {:error, {:invalid_phase, wire}}
    end
  end
end

defimpl Jason.Encoder, for: CrestCiContract.JobStatus do
  def encode(status, opts) do
    status
    |> CrestCiContract.JobStatus.to_wire()
    |> Jason.Encode.map(opts)
  end
end
