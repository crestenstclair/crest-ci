defmodule CrestCiController.PlanFromDefinition do
  @moduledoc """
  Resolves the job DAG `CrestCiController.RunReconciler` should reconcile a
  `WorkflowRun` against: a hand-built `WorkflowRunSpec.plan` (every asset
  before this one) passes straight through unchanged; a run whose spec
  carries `workflowYaml` and no hand-built plan has that YAML expanded by
  the pure `domainService.Engine` pipeline
  (`CrestCiController.Engine.WorkflowParser.parse/1` ->
  `CrestCiController.Engine.GithubContext.new/1` ->
  `CrestCiController.Engine.Planner.plan/2`) exactly once, "at first
  reconcile" — a run whose `WorkflowRunStatus.plan` is already non-empty
  (a prior tick already ran the engine successfully) never re-runs it.

  `workflowYaml` is read straight off the run's raw wire `spec` map, never
  modeled on `CrestCiContract.WorkflowRunSpec` itself: it is consumed only
  here, only until a plan is derived from it, and `WorkflowRunSpec.plan`
  remains the single field every other resource in this bounded context
  reads to learn a run's job DAG — the exact same design already proven
  out by `SimRunner.Demo.ControllerInstance.effective_plan/1`, this
  resource's harness-side counterpart.

  `resolve_plan/3` is a pure function: it never touches
  `CrestCiContract.KubeClient` itself. Persisting a freshly-derived plan
  (or a structured `PlanError`) into the run's `status` — via
  `CrestCiContract.WorkflowRunStatus.put_plan/2` /
  `.mark_plan_failed/2`, CAS'd through `patch_status`, before any job
  creation is ever proposed from it — is `CrestCiController.RunReconciler`'s
  job, mirroring how it already owns every other status-subresource write
  this bounded context makes (Single Responsibility: this module only
  ever answers "what plan should this tick reconcile against", never "how
  is that persisted").
  """

  alias CrestCiContract.{PlanJob, WorkflowRunSpec, WorkflowRunStatus}
  alias CrestCiController.Engine.{GithubContext, Planner, WorkflowParser}

  @default_event_name "workflow_dispatch"

  @typedoc """
  Why `resolve_plan/3` returned the plan it did:

    * `:hand_planned` — `spec.plan` was already non-empty; the engine was
      never consulted (a hand-planned run "continues to work unchanged").
    * `:already_planned` — `spec.plan` was empty but `status.plan` already
      carried a prior successful engine expansion; recomputation was
      skipped ("at first reconcile" semantics — the engine runs at most
      once per run).
    * `:no_plan` — neither a hand-built plan, a previously-derived plan,
      nor a `workflowYaml` to expand were present; the returned plan is
      `[]`, matching this run's behavior before the engine path existed.
    * `:freshly_planned` — the engine ran during THIS call and produced
      the returned plan; the caller (`RunReconciler`) is responsible for
      persisting it into the run's status before proposing any job
      creation from it.
  """
  @type origin :: :hand_planned | :already_planned | :no_plan | :freshly_planned

  @doc """
  Resolves the plan `workflow_run` should reconcile against for this
  tick, given the run's already-decoded `spec`, its raw wire `spec` map
  (`spec_wire` — the only place `workflowYaml` is read from), and its
  already-decoded `status`.

  Returns `{:ok, origin, plan}` on success (see `t:origin/0` for what the
  caller must do with each origin), or `{:error, plan_error}` — a
  structured `CrestCiController.Engine.Planner.plan_error()` wrapped in
  `{:plan_from_definition_failed, _}` — when `workflowYaml` failed to
  parse or expand. A `PlanError` never raises and never falls back to an
  empty plan; the caller must treat it as "this run cannot proceed" (mark
  Failed, propose no job creation), never silently continue as if no
  `workflowYaml` had been given at all.
  """
  @spec resolve_plan(WorkflowRunSpec.t(), map(), WorkflowRunStatus.t()) ::
          {:ok, origin(), [PlanJob.t()]} | {:error, term()}
  def resolve_plan(spec, spec_wire, status)

  def resolve_plan(%WorkflowRunSpec{plan: [_ | _] = plan}, _spec_wire, _status) do
    {:ok, :hand_planned, plan}
  end

  def resolve_plan(%WorkflowRunSpec{plan: []}, _spec_wire, %WorkflowRunStatus{
        plan: [_ | _] = plan
      }) do
    {:ok, :already_planned, plan}
  end

  def resolve_plan(%WorkflowRunSpec{plan: []} = spec, spec_wire, %WorkflowRunStatus{plan: []})
      when is_map(spec_wire) do
    case Map.get(spec_wire, "workflowYaml", "") do
      yaml when is_binary(yaml) and yaml != "" ->
        case plan_from_definition(yaml, spec) do
          {:ok, plan} -> {:ok, :freshly_planned, plan}
          {:error, _reason} = error -> error
        end

      _absent ->
        {:ok, :no_plan, []}
    end
  end

  # -- The pure engine pipeline: workflowYaml -> WorkflowDefinition -> plan --

  @spec plan_from_definition(String.t(), WorkflowRunSpec.t()) ::
          {:ok, [PlanJob.t()]} | {:error, {:plan_from_definition_failed, term()}}
  defp plan_from_definition(workflow_yaml, %WorkflowRunSpec{} = spec) do
    with {:ok, definition, _warnings} <- WorkflowParser.parse(workflow_yaml),
         {:ok, github_context} <- build_github_context(spec),
         {:ok, plan} <- Planner.plan(definition, github_context) do
      {:ok, plan}
    else
      {:error, reason} -> {:error, {:plan_from_definition_failed, reason}}
    end
  end

  # No trigger-event payload is available at this tier (a WorkflowRun
  # carries the resolved repo/ref/sha, not the raw webhook body that
  # produced them) — every other `github.*` field a job's `if:`/`runs-on:`
  # expression might reference (`actor`, `event`) is empty/absent rather
  # than guessed, matching `GithubContext.from_event/2`'s own fallback
  # shape for trigger types this C1 slice does not special-case.
  @spec build_github_context(WorkflowRunSpec.t()) :: {:ok, GithubContext.t()} | {:error, term()}
  defp build_github_context(%WorkflowRunSpec{ref: ref, repo: repo, sha: sha}) do
    GithubContext.new(%{
      actor: "",
      event: %{},
      event_name: @default_event_name,
      ref: ref,
      repository: repo,
      sha: sha
    })
  end
end
