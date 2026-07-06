defmodule CrestCiController.NeedsResolver do
  @moduledoc """
  Pure domain service: given a `WorkflowRun`'s expanded job DAG (`plan`,
  a list of `CrestCiContract.PlanJob`) and the current per-job execution
  records (`job_statuses`, keyed by `CrestCiContract.JobKey` to
  `CrestCiContract.JobStatus`), decides which jobs are ready to run,
  which must be skipped because a declared dependency did not succeed,
  and whether the run as a whole has reached a terminal
  `CrestCiContract.WorkflowRunPhase`.

  This module has no I/O, no process state, and does not itself write
  anything back to Kubernetes — `resolve/2` is a pure, deterministic
  function of its two arguments: identical `(plan, job_statuses)` input
  always yields identical output. Callers (`RunReconciler`) are
  responsible for turning the proposal into `patch_status` calls guarded
  by optimistic concurrency.

  ## Runnable / skip classification

  A plan job is only ever classified as runnable or to-skip while its own
  current status is still `:waiting` (i.e. it has not yet been queued,
  assigned, run, skipped, or otherwise terminated). A job already beyond
  `:waiting` is left out of both lists — proposing it again would not be
  idempotent, and re-reconciling after a crash or a replayed watch event
  must be a no-op for jobs already acted upon.

  For a `:waiting` job, each of its declared `needs` is inspected via the
  current `JobStatus.phase` of the referenced job (defaulting to
  `:waiting` when the referenced key has no status yet, i.e. it has not
  been observed/created):

    * if any `needs` entry is `:failed`, `:cancelled`, or `:skipped` (a
      dependency that will never produce a successful result, including
      one already skipped for the same reason), the job is added to
      `skip_job_keys` — dependency failure/skip cascades to dependents;
    * else if every `needs` entry is `:succeeded`, the job is added to
      `runnable_job_keys`;
    * otherwise (at least one `needs` entry is still `:waiting`,
      `:queued`, `:assigned`, or `:running` — unresolved) the job is left
      out of both lists: it is never marked runnable while any dependency
      is still unresolved.

  A job with an empty `needs` list is vacuously runnable (once it is
  itself still `:waiting`).

  ## Terminal detection

  `terminal` is `true`, and `phase` is a terminal
  `CrestCiContract.WorkflowRunPhase` (`:succeeded`, `:failed`, or
  `:cancelled`), only once every plan job's current status phase is
  itself terminal (`:succeeded`, `:failed`, `:cancelled`, or `:skipped`).
  The aggregate `phase` is derived with `:failed` dominant over
  `:cancelled` dominant over an all-`:succeeded`/`:skipped` result being
  `:succeeded` — mirroring the same terminal-first priority used
  elsewhere in this system for phase aggregation, so the same job-status
  input always resolves to the same terminal phase regardless of
  arrival order. An empty `plan` has nothing to resolve and is reported
  as non-terminal (`terminal: false, phase: nil`).

  When not every job is terminal yet, `terminal` is `false` and `phase`
  is `nil` — aggregating a *non*-terminal run phase (`:pending`,
  `:queued`, `:running`) is the reconciler's concern, not this module's;
  `NeedsResolver` only ever reports a phase when it is the terminal,
  absorbing answer. Because a terminal job-status set always derives to
  the same terminal phase, this module never proposes a transition out
  of an already-terminal `WorkflowRunPhase`.
  """

  alias CrestCiContract.{JobKey, JobStatus, PlanJob, WorkflowRunPhase}

  @job_negative_terminal_phases [:failed, :cancelled, :skipped]
  @job_terminal_phases [:succeeded, :failed, :cancelled, :skipped]

  @type result :: %{
          runnable_job_keys: [JobKey.t()],
          skip_job_keys: [JobKey.t()],
          terminal: boolean(),
          phase: WorkflowRunPhase.t() | nil
        }

  @doc """
  Resolves the next runnable/skip proposal and terminal status for a
  plan against the current job statuses. See the moduledoc for the full
  classification and terminal-detection rules.

  Pure and deterministic: does not read or write anything outside its
  arguments.
  """
  @spec resolve([PlanJob.t()], %{optional(JobKey.t()) => JobStatus.t()}) :: result()
  def resolve(plan, job_statuses) when is_list(plan) and is_map(job_statuses) do
    {runnable, skip} =
      Enum.reduce(plan, {[], []}, fn %PlanJob{} = job, {runnable_acc, skip_acc} ->
        case classify(job, job_statuses) do
          :runnable -> {[job.key | runnable_acc], skip_acc}
          :skip -> {runnable_acc, [job.key | skip_acc]}
          :not_yet_actionable -> {runnable_acc, skip_acc}
        end
      end)

    {terminal, phase} = terminal_phase(plan, job_statuses)

    %{
      runnable_job_keys: Enum.reverse(runnable),
      skip_job_keys: Enum.reverse(skip),
      terminal: terminal,
      phase: phase
    }
  end

  @spec classify(PlanJob.t(), %{optional(JobKey.t()) => JobStatus.t()}) ::
          :runnable | :skip | :not_yet_actionable
  defp classify(%PlanJob{} = job, job_statuses) do
    if phase_of(job.key, job_statuses) == :waiting do
      needs_phases = Enum.map(job.needs, &phase_of(&1, job_statuses))

      cond do
        Enum.any?(needs_phases, &(&1 in @job_negative_terminal_phases)) -> :skip
        Enum.all?(needs_phases, &(&1 == :succeeded)) -> :runnable
        true -> :not_yet_actionable
      end
    else
      :not_yet_actionable
    end
  end

  @spec phase_of(JobKey.t(), %{optional(JobKey.t()) => JobStatus.t()}) :: JobStatus.phase()
  defp phase_of(job_key, job_statuses) do
    case Map.fetch(job_statuses, job_key) do
      {:ok, %JobStatus{phase: phase}} -> phase
      :error -> :waiting
    end
  end

  @spec terminal_phase([PlanJob.t()], %{optional(JobKey.t()) => JobStatus.t()}) ::
          {boolean(), WorkflowRunPhase.t() | nil}
  defp terminal_phase([], _job_statuses), do: {false, nil}

  defp terminal_phase(plan, job_statuses) do
    job_phases = Enum.map(plan, fn %PlanJob{key: key} -> phase_of(key, job_statuses) end)

    if Enum.all?(job_phases, &(&1 in @job_terminal_phases)) do
      phase = aggregate_terminal_phase(job_phases)
      {WorkflowRunPhase.terminal?(phase), phase}
    else
      {false, nil}
    end
  end

  @spec aggregate_terminal_phase([JobStatus.phase()]) :: WorkflowRunPhase.t()
  defp aggregate_terminal_phase(job_phases) do
    cond do
      Enum.any?(job_phases, &(&1 == :failed)) -> :failed
      Enum.any?(job_phases, &(&1 == :cancelled)) -> :cancelled
      true -> :succeeded
    end
  end
end
