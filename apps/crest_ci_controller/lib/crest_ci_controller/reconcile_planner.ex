defmodule CrestCiController.ReconcilePlanner do
  @moduledoc """
  Pure domain service: given one `WorkflowRun`'s current observed state
  (its expanded `plan`, the per-job `job_statuses`, and its current
  aggregate `phase`) and the deterministic `RunnerJob` names already known
  to exist, computes the full list of side-effect commands that would
  converge the world — without performing any of them.

  `ReconcilePlanner.plan/2` has no I/O and no process state: it is a
  deterministic function of its two arguments alone. The caller (a
  reconciler process) is the only place that turns the returned commands
  into `CrestCiContract.KubeClient` calls, guarded by 409-tolerant
  creates and CAS'd `patch_status` writes — this module never talks to
  Kubernetes itself.

  ## How the plan is derived

  Runnable/skip classification is delegated entirely to
  `CrestCiController.NeedsResolver.resolve/2` — this module does not
  re-derive dependency logic, it only turns that pure proposal into
  commands:

    * every job key in `runnable_job_keys` gets a `{:create_runner_job,
      _}` and a paired `{:create_pod, _}` command, unless a `RunnerJob`
      with that job's deterministic name is already present in
      `existing_runner_jobs` — in which case no create command is
      emitted for it at all. This is what keeps replanning idempotent:
      re-running `plan/2` against a world where its own prior commands
      already landed produces no duplicate create commands, even before
      the 409-tolerant `create` semantics at the KubeClient layer would
      have absorbed the duplicate anyway;
    * child names are derived purely via
      `CrestCiContract.DeterministicNaming.runner_job_name/2` and
      `.pod_name/2` from the run's `ulid` and the job's `JobKey` —
      identical `(ulid, job_key)` pairs always yield identical names,
      so a failover controller re-planning the same run never invents a
      new name for the same logical child;
    * a single `{:patch_status, _}` command is emitted carrying the
      updated `jobs` map (skip-classified jobs moved to `:skipped`,
      runnable jobs moved to `:queued`, everything else left untouched)
      and the updated aggregate `phase` — derived via
      `CrestCiContract.WorkflowRunStatus.update_jobs/2`, which itself
      guards the terminal-phase absorption rule
      (`CrestCiContract.WorkflowRunPhase.transition_allowed?/2`), so
      `plan/2` never proposes a transition out of an already-terminal
      phase. When neither the jobs map nor the phase would actually
      change, no `{:patch_status, _}` command is emitted at all — a
      true no-op tick converges to zero commands.

  ## Child job placement and payload

  A runnable job's `RunnerJobSpec` is built from its `PlanJob`: `runs_on`
  defaults to `["default"]` when the plan job declares no placement
  labels (a `RunnerJobSpec` cannot represent an empty placement — see
  `CrestCiContract.RunnerJobSpec.new/1`), and `job_message` carries the
  plan job's raw `steps` under a `"steps"` key, opaque to this module.

  `plan/2` never mutates the arguments it is given and never orders
  commands by anything other than the plan's own declared order — the
  same `(workflow_run, existing_runner_jobs)` input always yields the
  same command list, in the same order, every time.
  """

  alias CrestCiContract.{
    DeterministicNaming,
    JobKey,
    JobStatus,
    PlanJob,
    RunnerJobSpec,
    WorkflowRunPhase,
    WorkflowRunStatus
  }

  alias CrestCiController.NeedsResolver

  @workflow_run_api_version "ci.crest.dev/v1alpha1"
  @workflow_run_kind "WorkflowRun"
  @runner_job_kind "RunnerJob"
  @default_runs_on ["default"]

  @typedoc """
  The pure input describing one `WorkflowRun`'s current observed state.

    * `:ulid` — the run's `CrestCiContract.Ulid`, used (with each job's
      `JobKey`) to derive deterministic child names;
    * `:run_ref` — the parent run's identifier, carried through onto
      every child `RunnerJobSpec.run_ref`;
    * `:plan` — the run's expanded job DAG (`[CrestCiContract.PlanJob.t()]`);
    * `:job_statuses` — the current per-job execution records, keyed by
      `JobKey` (defaults to `%{}` — every plan job defaults to
      `:waiting` when absent, per `NeedsResolver`);
    * `:phase` — the run's current aggregate
      `CrestCiContract.WorkflowRunPhase` (defaults to `:pending`).
  """
  @type workflow_run :: %{
          required(:ulid) => String.t(),
          required(:run_ref) => String.t(),
          required(:plan) => [PlanJob.t()],
          optional(:job_statuses) => %{optional(JobKey.t()) => JobStatus.t()},
          optional(:phase) => WorkflowRunPhase.t()
        }

  @typedoc """
  Deterministic `RunnerJob` names already known to exist (e.g. freshly
  observed via a `list` call) — used only to suppress redundant create
  commands, never to suppress a `{:patch_status, _}` command.
  """
  @type existing_runner_jobs :: [String.t()]

  @type owner_ref :: %{api_version: String.t(), kind: String.t(), name: String.t()}

  @type create_runner_job_command :: %{
          name: String.t(),
          job_key: JobKey.t(),
          owner_ref: owner_ref(),
          runner_job_spec: RunnerJobSpec.t()
        }

  @type create_pod_command :: %{name: String.t(), owner_ref: owner_ref()}

  @type patch_status_command :: %{
          jobs: %{optional(JobKey.t()) => JobStatus.t()},
          phase: WorkflowRunPhase.t()
        }

  @type command ::
          {:create_runner_job, create_runner_job_command()}
          | {:create_pod, create_pod_command()}
          | {:patch_status, patch_status_command()}

  @doc """
  Computes the full list of side-effect commands that would converge the
  world for one `WorkflowRun`, given the deterministic `RunnerJob` names
  already known to exist.

  Pure and deterministic — see the moduledoc for the full derivation.
  """
  @spec plan(workflow_run(), existing_runner_jobs()) :: [command()]
  def plan(%{ulid: ulid, run_ref: run_ref, plan: plan_jobs} = workflow_run, existing_runner_jobs)
      when is_binary(ulid) and is_binary(run_ref) and is_list(plan_jobs) and
             is_list(existing_runner_jobs) do
    job_statuses = Map.get(workflow_run, :job_statuses, %{})
    current_phase = Map.get(workflow_run, :phase, :pending)

    proposal = NeedsResolver.resolve(plan_jobs, job_statuses)
    existing = MapSet.new(existing_runner_jobs)

    create_commands =
      Enum.flat_map(
        proposal.runnable_job_keys,
        &child_create_commands(&1, plan_jobs, ulid, run_ref, existing)
      )

    create_commands ++ status_commands(job_statuses, current_phase, proposal)
  end

  # -- Child creation (deterministic naming; no create when already known) --

  @spec child_create_commands(JobKey.t(), [PlanJob.t()], String.t(), String.t(), MapSet.t()) ::
          [command()]
  defp child_create_commands(job_key, plan_jobs, ulid, run_ref, existing) do
    runner_job_name = DeterministicNaming.runner_job_name(ulid, job_key)

    if MapSet.member?(existing, runner_job_name) do
      []
    else
      build_create_commands(job_key, plan_jobs, ulid, run_ref, runner_job_name)
    end
  end

  @spec build_create_commands(JobKey.t(), [PlanJob.t()], String.t(), String.t(), String.t()) ::
          [command()]
  defp build_create_commands(job_key, plan_jobs, ulid, run_ref, runner_job_name) do
    pod_name = DeterministicNaming.pod_name(ulid, job_key)
    plan_job = Enum.find(plan_jobs, &(&1.key == job_key))

    {:ok, runner_job_spec} =
      RunnerJobSpec.new(%{
        job_key: job_key,
        run_ref: run_ref,
        runs_on: runs_on_for(plan_job),
        job_message: %{"steps" => steps_for(plan_job)}
      })

    runner_job_owner = %{
      api_version: @workflow_run_api_version,
      kind: @workflow_run_kind,
      name: ulid
    }

    pod_owner = %{
      api_version: @workflow_run_api_version,
      kind: @runner_job_kind,
      name: runner_job_name
    }

    [
      {:create_runner_job,
       %{
         name: runner_job_name,
         job_key: job_key,
         owner_ref: runner_job_owner,
         runner_job_spec: runner_job_spec
       }},
      {:create_pod, %{name: pod_name, owner_ref: pod_owner}}
    ]
  end

  @spec runs_on_for(PlanJob.t() | nil) :: [String.t(), ...]
  defp runs_on_for(%PlanJob{runs_on: []}), do: @default_runs_on
  defp runs_on_for(%PlanJob{runs_on: runs_on}), do: runs_on
  defp runs_on_for(nil), do: @default_runs_on

  @spec steps_for(PlanJob.t() | nil) :: [map()]
  defp steps_for(%PlanJob{steps: steps}), do: steps
  defp steps_for(nil), do: []

  # -- Status patch (skip/queue transitions + terminal-gated phase) ---------

  @spec status_commands(
          %{optional(JobKey.t()) => JobStatus.t()},
          WorkflowRunPhase.t(),
          NeedsResolver.result()
        ) :: [command()]
  defp status_commands(job_statuses, current_phase, proposal) do
    updated_jobs = apply_transitions(job_statuses, proposal)

    new_status =
      WorkflowRunStatus.update_jobs(
        %WorkflowRunStatus{jobs: job_statuses, phase: current_phase},
        updated_jobs
      )

    if new_status.jobs == job_statuses and new_status.phase == current_phase do
      []
    else
      [{:patch_status, %{jobs: new_status.jobs, phase: new_status.phase}}]
    end
  end

  @spec apply_transitions(%{optional(JobKey.t()) => JobStatus.t()}, NeedsResolver.result()) ::
          %{optional(JobKey.t()) => JobStatus.t()}
  defp apply_transitions(job_statuses, %{
         skip_job_keys: skip_job_keys,
         runnable_job_keys: runnable_job_keys
       }) do
    job_statuses
    |> mark(skip_job_keys, :skipped)
    |> mark(runnable_job_keys, :queued)
  end

  @spec mark(%{optional(JobKey.t()) => JobStatus.t()}, [JobKey.t()], JobStatus.phase()) ::
          %{optional(JobKey.t()) => JobStatus.t()}
  defp mark(job_statuses, keys, phase) do
    Enum.reduce(keys, job_statuses, fn key, acc ->
      Map.update(acc, key, new_job_status(phase), &transition(&1, phase))
    end)
  end

  @spec new_job_status(JobStatus.phase()) :: JobStatus.t()
  defp new_job_status(phase) do
    {:ok, status} = JobStatus.new(%{phase: phase})
    status
  end

  @spec transition(JobStatus.t(), JobStatus.phase()) :: JobStatus.t()
  defp transition(%JobStatus{} = current, phase) do
    case JobStatus.update(current, %{phase: phase}) do
      {:ok, updated} -> updated
      {:error, _reason} -> current
    end
  end
end
