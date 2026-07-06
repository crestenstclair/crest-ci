defmodule CrestCiContract.WorkflowRunStatus do
  @moduledoc """
  Aggregate run state carried in a `WorkflowRun`'s `status` subresource:
  the per-job execution records (`jobs`, keyed by `JobKey` -> `JobStatus`)
  plus the run's own `phase`, drawn from the closed enumeration guarded by
  `CrestCiContract.WorkflowRunPhase`.

  `phase` is never set independently of `jobs` — it is always a pure
  derivation (`derive_phase/1`) of the job phases inside `jobs`. There is
  no public API that accepts an arbitrary `phase` value alongside `jobs`.

  Legality of *changing* an existing status's phase is delegated entirely
  to `CrestCiContract.WorkflowRunPhase.transition_allowed?/2`: terminal
  phases (`Succeeded`, `Failed`, `Cancelled`) are absorbing, so
  `update_jobs/2` never moves a status back out of a terminal phase no
  matter how the underlying `jobs` map changes, and `from_wire/1` respects
  a terminal phase already recorded on the wire rather than recomputing
  past it. This mirrors the controller's reconciliation discipline — a
  controller replica reconciling from a fresh Kubernetes watch (any order,
  possibly replayed) must land on the same terminal status, never regress
  it.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1`, and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls.

  `plan` and `plan_error` carry the *engine*-derived job DAG for a
  `workflowYaml`-driven run (see `CrestCiController.PlanFromDefinition`):
  `plan` is populated exactly once, via `put_plan/2`, the first time the
  engine successfully expands such a run's `workflowYaml`; `plan_error`
  is populated via `mark_plan_failed/2` when it does not. A hand-planned
  run (whose `WorkflowRunSpec.plan` is already non-empty) never touches
  either field — both stay at their defaults (`[]` / `""`). Neither field
  is ever emitted on the wire when still at its default, so a status that
  never went through the engine path round-trips byte-identically to how
  it did before these fields existed.
  """

  alias CrestCiContract.{JobKey, JobStatus, PlanJob, WorkflowRunPhase}

  @type phase :: WorkflowRunPhase.t()

  @type t :: %__MODULE__{
          jobs: %{optional(JobKey.t()) => JobStatus.t()},
          phase: phase(),
          plan: [PlanJob.t()],
          plan_error: String.t()
        }

  @enforce_keys [:jobs, :phase]
  defstruct jobs: %{}, phase: :pending, plan: [], plan_error: ""

  @doc "The closed set of legal `phase` values, delegating to `WorkflowRunPhase.values/0`."
  @spec phases() :: [phase()]
  def phases, do: WorkflowRunPhase.values()

  @doc """
  Builds a new `WorkflowRunStatus` from a `jobs` map. `phase` is always
  derived from `jobs` via `derive_phase/1` — there is no way to construct
  a status with a `phase` inconsistent with its `jobs`.
  """
  @spec new(%{optional(JobKey.t()) => JobStatus.t()}) :: t()
  def new(jobs \\ %{}) when is_map(jobs) do
    %__MODULE__{jobs: jobs, phase: derive_phase(jobs)}
  end

  @doc """
  Replaces the `jobs` map on an existing status and recomputes `phase`,
  gated by `WorkflowRunPhase.transition_allowed?/2`: if the freshly
  derived phase is not a legal transition from the status's current
  phase (i.e. the current phase is terminal and the derived phase
  differs), the phase does not change. Otherwise the phase becomes the
  fresh derivation from the new `jobs` map.
  """
  @spec update_jobs(t(), %{optional(JobKey.t()) => JobStatus.t()}) :: t()
  def update_jobs(%__MODULE__{phase: current_phase} = status, jobs) when is_map(jobs) do
    candidate_phase = derive_phase(jobs)

    new_phase =
      if WorkflowRunPhase.transition_allowed?(current_phase, candidate_phase) do
        candidate_phase
      else
        current_phase
      end

    %{status | jobs: jobs, phase: new_phase}
  end

  @doc """
  Records the job DAG an engine expansion produced for a `workflowYaml`
  -driven run — see `CrestCiController.PlanFromDefinition`. Called at
  most once per run, the first time the engine successfully expands its
  `workflowYaml` (a hand-planned run's `WorkflowRunSpec.plan` is already
  non-empty and never reaches this function). Touches only `plan` —
  `jobs` and `phase` are untouched, so a caller can persist a freshly
  derived plan independently of any job-status bookkeeping.
  """
  @spec put_plan(t(), [PlanJob.t()]) :: t()
  def put_plan(%__MODULE__{} = status, plan) when is_list(plan) do
    %{status | plan: plan}
  end

  @doc """
  Marks a run Failed with a structured `PlanError` recorded in
  `plan_error`, for a `workflowYaml`-driven run whose engine expansion
  failed (an unknown `needs` target, a `needs` cycle, or any other
  `CrestCiController.Engine.Planner` error). Gated by the same
  terminal-phase absorption rule as `update_jobs/2`
  (`CrestCiContract.WorkflowRunPhase.transition_allowed?/2`): a run
  already in a terminal phase never has its phase forced back to Failed
  by a later plan-error observation.
  """
  @spec mark_plan_failed(t(), String.t()) :: t()
  def mark_plan_failed(%__MODULE__{phase: current_phase} = status, reason)
      when is_binary(reason) do
    new_phase =
      if WorkflowRunPhase.transition_allowed?(current_phase, :failed) do
        :failed
      else
        current_phase
      end

    %{status | phase: new_phase, plan_error: reason}
  end

  @doc """
  Pure derivation of the aggregate run `phase` from a `jobs` map of
  `JobStatus` values. Deterministic and side-effect free: identical
  `jobs` input always yields an identical `phase` output.

  Rules, evaluated in order:

    * no jobs at all -> `:pending`
    * any job `:failed` -> `:failed`
    * any job `:cancelled` (and none failed) -> `:cancelled`
    * every job `:succeeded` or `:skipped` -> `:succeeded`
    * any job `:running` or `:assigned` -> `:running`
    * any job `:queued` -> `:queued`
    * otherwise (every job still `:waiting`) -> `:pending`
  """
  @spec derive_phase(%{optional(JobKey.t()) => JobStatus.t()}) :: phase()
  def derive_phase(jobs) when is_map(jobs) and map_size(jobs) == 0, do: :pending

  def derive_phase(jobs) when is_map(jobs) do
    job_phases = jobs |> Map.values() |> Enum.map(& &1.phase)

    cond do
      Enum.any?(job_phases, &(&1 == :failed)) -> :failed
      Enum.any?(job_phases, &(&1 == :cancelled)) -> :cancelled
      Enum.all?(job_phases, &(&1 in [:succeeded, :skipped])) -> :succeeded
      Enum.any?(job_phases, &(&1 in [:running, :assigned])) -> :running
      Enum.any?(job_phases, &(&1 == :queued)) -> :queued
      true -> :pending
    end
  end

  @doc """
  Decodes a `WorkflowRunStatus` from its Kubernetes JSON wire shape: a map
  with a `"jobs"` object (string `JobKey` keys -> `JobStatus` wire maps)
  and a `"phase"` string drawn from the declared enum.

  The decoded `phase` is not blindly trusted: if the wire `phase` is
  already terminal (`WorkflowRunPhase.terminal?/1`), it is preserved
  as-is (absorbing); otherwise the phase is recomputed from `jobs` via
  `derive_phase/1`, so `phase` can never observably diverge from a fresh
  derivation except by staying in an already-terminal state. Returns
  `{:error, :invalid_workflow_run_phase}` or
  `{:error, {:invalid_job_phase, key, term}}` when a phase value falls
  outside its closed enumeration.
  """
  @spec from_wire(map()) ::
          {:ok, t()}
          | {:error, :invalid_workflow_run_phase}
          | {:error, {:invalid_job_phase, term(), term()}}
          | {:error, {:invalid_plan, term()}}
  def from_wire(%{} = wire) do
    with {:ok, jobs} <- decode_jobs(Map.get(wire, "jobs", %{})),
         {:ok, plan} <- decode_plan_wire(Map.get(wire, "plan", [])),
         {:ok, wire_phase} <- WorkflowRunPhase.from_wire(Map.get(wire, "phase", "Pending")) do
      phase = if WorkflowRunPhase.terminal?(wire_phase), do: wire_phase, else: derive_phase(jobs)
      plan_error = Map.get(wire, "planError", "")
      {:ok, %__MODULE__{jobs: jobs, phase: phase, plan: plan, plan_error: plan_error}}
    end
  end

  @doc """
  Encodes a `WorkflowRunStatus` into its Kubernetes JSON wire shape
  (camelCase keys). `"plan"` and `"planError"` are only emitted when
  non-default (a non-empty `plan` / a non-empty `plan_error`) — a status
  that never went through the engine path (see `put_plan/2` /
  `mark_plan_failed/2`) encodes exactly as it did before these fields
  existed.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = status) do
    %{
      "jobs" =>
        Map.new(status.jobs, fn {key, job_status} -> {key, JobStatus.to_wire(job_status)} end),
      "phase" => WorkflowRunPhase.to_wire(status.phase)
    }
    |> maybe_put_plan(status.plan)
    |> maybe_put_plan_error(status.plan_error)
  end

  @spec maybe_put_plan(map(), [PlanJob.t()]) :: map()
  defp maybe_put_plan(wire, []), do: wire
  defp maybe_put_plan(wire, plan), do: Map.put(wire, "plan", Enum.map(plan, &PlanJob.to_wire/1))

  @spec maybe_put_plan_error(map(), String.t()) :: map()
  defp maybe_put_plan_error(wire, ""), do: wire
  defp maybe_put_plan_error(wire, plan_error), do: Map.put(wire, "planError", plan_error)

  @spec decode_plan_wire(term()) :: {:ok, [PlanJob.t()]} | {:error, {:invalid_plan, term()}}
  defp decode_plan_wire(plan) when is_list(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, fn job_wire, {:ok, acc} ->
      case PlanJob.from_wire(job_wire) do
        {:ok, job} -> {:cont, {:ok, [job | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_plan, reason}}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_plan_wire(other), do: {:error, {:invalid_plan, other}}

  @spec decode_jobs(term()) ::
          {:ok, %{optional(JobKey.t()) => JobStatus.t()}}
          | {:error, {:invalid_job_phase, term(), term()}}
  defp decode_jobs(jobs_wire) when is_map(jobs_wire) do
    Enum.reduce_while(jobs_wire, {:ok, %{}}, fn {key, status_wire}, {:ok, acc} ->
      case JobStatus.from_wire(status_wire) do
        {:ok, job_status} -> {:cont, {:ok, Map.put(acc, key, job_status)}}
        {:error, reason} -> {:halt, {:error, {:invalid_job_phase, key, reason}}}
      end
    end)
  end

  defp decode_jobs(_other), do: {:error, {:invalid_job_phase, nil, :not_a_map}}
end

defimpl Jason.Encoder, for: CrestCiContract.WorkflowRunStatus do
  def encode(status, opts) do
    status
    |> CrestCiContract.WorkflowRunStatus.to_wire()
    |> Jason.Encode.map(opts)
  end
end
