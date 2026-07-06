defmodule CrestCiController.Engine.JobMessageRenderer do
  @moduledoc """
  Pure domain service: renders one `PlanJob` into the `job_message` map
  the gateway serves to a runner over its long-poll connection (the
  opaque payload `CrestCiContract.RunnerJobSpec.job_message` carries).

  The render honors the same client/server split as
  `CrestCiController.Engine.ContextAssembler` and
  `CrestCiController.Engine.ExpressionEvaluator`: the controller's scope
  stops at the job tier.

    * `"steps"` — the job's steps exactly as declared on the `PlanJob`,
      byte-for-byte, including any `${{ }}` expressions they contain.
      Step-level expressions are GitHub's own runner-side tier and this
      module never parses, evaluates, or otherwise touches step bodies —
      it only carries them through unchanged, same as `PlanJob` itself
      does for `steps`.
    * `"env"` — the job-tier environment, already resolved by
      `ContextAssembler.build/1` (workflow `env:` merged with job `env:`,
      job winning on collision). This is the fully server-evaluated
      scope; nothing about it is deferred to the runner.
    * `"needs"` — the needs outputs snapshot: for every job id the
      `PlanJob` declares in `needs`, the dependency's terminal result and
      its `outputs`, exactly as `ContextAssembler.build/1` assembled it.
      This snapshot is what lets the runner resolve any
      `${{ needs.<job>.outputs.<name> }}` reference appearing inside an
      unevaluated step body, without the controller having to parse step
      contents to find those references.

  Pure function module: no processes, no I/O, no clock reads. `render/2`
  is a deterministic function of its two arguments — identical
  `(plan_job, context_fields)` input always produces a byte-identical
  job message. This falls directly out of `ContextAssembler.build/1`'s
  own determinism and out of `PlanJob.steps` being carried through
  unchanged: nothing in this module reads wall-clock time, generates an
  id, or otherwise introduces incidental variation. Small maps (up to 32
  keys) in the BEAM iterate in key-sorted order regardless of
  construction history, so encoding the same key/value set (e.g. via
  `Jason.encode!/1`) is itself stable across calls and processes — this
  module does not need to impose its own key ordering on top of that.

  Building the job-tier evaluation context (the `github` / `needs` /
  `env` branches) is explicitly delegated to `ContextAssembler.build/1`
  rather than re-implemented here — this module has exactly one reason
  to change: how a `PlanJob` and an already-assembled context combine
  into the final rendered job message, not how that context itself gets
  built. Any error `ContextAssembler.build/1` reports (a malformed field,
  a missing or non-terminal `needs` dependency) is surfaced unchanged, so
  a caller that asks this module to render a job whose dependencies
  are not actually satisfied yet gets the same loud, tagged error
  `ContextAssembler` would have given it directly, not a silently wrong
  render.
  """

  alias CrestCiController.Engine.ContextAssembler
  alias CrestCiContract.PlanJob

  @type job_message :: %{String.t() => term()}

  @type render_error ::
          ContextAssembler.build_error()
          | {:invalid_plan_job, term()}
          | {:invalid_context_fields, term()}

  @doc """
  Renders `plan_job` into the job message map the gateway serves to a
  runner.

  `context_fields` is the same field map `ContextAssembler.build/1`
  accepts (`:github_context`, `:workflow_env`, `:job_env`, `:needs`,
  `:job_statuses`) — this module builds the job-tier context itself via
  that dependency rather than requiring the caller to pre-assemble it.

  Returns `{:ok, job_message}` where `job_message` is a plain
  string-keyed map with `"steps"`, `"env"`, and `"needs"` branches.
  Returns `{:error, reason}` when `plan_job` is not a `PlanJob`, when
  `context_fields` is not a map, or when `ContextAssembler.build/1`
  itself rejects `context_fields` (a malformed field, or a `needs` entry
  that is missing or not yet in a terminal phase).
  """
  @spec render(PlanJob.t(), map()) :: {:ok, job_message()} | {:error, render_error()}
  def render(%PlanJob{} = plan_job, context_fields) when is_map(context_fields) do
    with {:ok, context} <- ContextAssembler.build(context_fields) do
      {:ok,
       %{
         "steps" => plan_job.steps,
         "env" => Map.fetch!(context, "env"),
         "needs" => Map.fetch!(context, "needs")
       }}
    end
  end

  def render(%PlanJob{}, other), do: {:error, {:invalid_context_fields, other}}
  def render(other, _context_fields), do: {:error, {:invalid_plan_job, other}}
end
