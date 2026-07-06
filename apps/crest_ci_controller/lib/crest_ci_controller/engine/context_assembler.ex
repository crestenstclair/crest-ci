defmodule CrestCiController.Engine.ContextAssembler do
  @moduledoc """
  Builds the per-job GitHub Actions expression evaluation context: the
  `github`, `needs`, and `env` branches handed to the expression
  evaluator when the controller decides whether a job's `if:` runs and
  what its `env:` resolves to.

  Scope is deliberately narrow, mirroring GitHub's own client/server
  split of expression evaluation:

    * `github` — the trigger's `GithubContext`, projected via
      `CrestCiController.Engine.GithubContext.to_expr_context/1` (so
      `github.event_name`, `github.ref`, `github.sha`, etc. resolve
      exactly as they do in real GitHub Actions expressions).
    * `needs` — for every job id the current job declares in `needs`,
      the *result* (`"success"`, `"failure"`, `"cancelled"`, or
      `"skipped"`, mirrored from that job's `JobStatus.phase`) and
      *outputs* of that dependency, exposed as
      `needs.<job_id>.result` / `needs.<job_id>.outputs.<name>`.
    * `env` — the workflow-level `env:` merged with the job-level
      `env:`, job wins on key collision (GitHub Actions merge order).

  Step-level context assembly (each step's own `env:` merge on top of
  this job-level result, and `with:`/`inputs:` scope) is explicitly
  **not** done here — GitHub itself splits step evaluation to the
  runner, and this C1 slice follows the same split: steps ship
  unevaluated to the runner, which merges its own step `env:` on top
  of the job-level `env` this module produces.

  Pure function module: no processes, no I/O, no clock reads. Identical
  input always produces a byte-identical (or byte-identical-error)
  result — this module never reads wall-clock time or any other
  ambient state, so it does not itself decide whether a dependency
  "counts" as stale; it only reports what the given `JobStatus` says
  right now.

  A declared `needs` entry with no corresponding `job_statuses` entry,
  or one whose `JobStatus.phase` has not yet reached a terminal phase
  (`succeeded` / `failed` / `cancelled` / `skipped`), is a caller error:
  the controller must not ask this module to assemble a job's context
  until every job it needs has actually finished. `build/1` reports
  either condition as a tagged error rather than guessing or silently
  omitting the entry, so a scheduling bug that lets an unsatisfied
  dependency through is loud, not silently wrong.
  """

  alias CrestCiController.Engine.GithubContext
  alias CrestCiContract.JobStatus

  @terminal_phase_results %{
    succeeded: "success",
    failed: "failure",
    cancelled: "cancelled",
    skipped: "skipped"
  }

  @type job_id :: String.t()
  @type expr_context :: %{optional(String.t()) => term()}
  @type need_result :: %{String.t() => term()}

  @type build_error ::
          {:invalid_github_context, term()}
          | {:invalid_workflow_env, term()}
          | {:invalid_job_env, term()}
          | {:invalid_needs, term()}
          | {:invalid_job_statuses, term()}
          | {:missing_need_status, job_id()}
          | {:unsatisfied_need, job_id(), JobStatus.phase()}

  @doc """
  Assembles the `github` / `needs` / `env` evaluation context for one
  job from field values (atom keys):

    * `:github_context` — a `CrestCiController.Engine.GithubContext.t()`
      (required).
    * `:workflow_env` — the workflow-level `env:` map, binary keys and
      values (defaults to `%{}`).
    * `:job_env` — the job-level `env:` map, binary keys and values
      (defaults to `%{}`); wins over `:workflow_env` on key collision.
    * `:needs` — the list of job ids this job declares in `needs:`
      (defaults to `[]`); typically a `CrestCiContract.PlanJob.needs`
      list.
    * `:job_statuses` — a map of `job_id => JobStatus.t()` covering (at
      least) every id listed in `:needs` (defaults to `%{}`).

  Returns `{:ok, context}` where `context` is a plain string-keyed map
  with `"github"`, `"needs"`, and `"env"` branches, ready to hand to the
  expression evaluator as the job-level scope. Returns `{:error,
  reason}` when a field is malformed, or when a declared need is
  missing from `job_statuses` or has not yet reached a terminal phase.
  """
  @spec build(map()) :: {:ok, expr_context()} | {:error, build_error()}
  def build(fields) when is_map(fields) do
    with {:ok, github_context} <- validate_github_context(Map.get(fields, :github_context)),
         {:ok, workflow_env} <-
           validate_env(Map.get(fields, :workflow_env, %{}), :invalid_workflow_env),
         {:ok, job_env} <- validate_env(Map.get(fields, :job_env, %{}), :invalid_job_env),
         {:ok, needs} <- validate_needs(Map.get(fields, :needs, [])),
         {:ok, job_statuses} <- validate_job_statuses(Map.get(fields, :job_statuses, %{})),
         {:ok, needs_context} <- build_needs_context(needs, job_statuses) do
      {:ok,
       %{
         "github" => GithubContext.to_expr_context(github_context),
         "needs" => needs_context,
         "env" => Map.merge(workflow_env, job_env)
       }}
    end
  end

  def build(other), do: {:error, {:invalid_fields, other}}

  @spec build_needs_context([job_id()], %{optional(job_id()) => JobStatus.t()}) ::
          {:ok, %{optional(job_id()) => need_result()}} | {:error, build_error()}
  defp build_needs_context(needs, job_statuses) do
    Enum.reduce_while(needs, {:ok, %{}}, fn job_id, {:ok, acc} ->
      case need_result(job_id, job_statuses) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, job_id, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec need_result(job_id(), %{optional(job_id()) => JobStatus.t()}) ::
          {:ok, need_result()} | {:error, build_error()}
  defp need_result(job_id, job_statuses) do
    case Map.fetch(job_statuses, job_id) do
      :error ->
        {:error, {:missing_need_status, job_id}}

      {:ok, %JobStatus{phase: phase, outputs: outputs}} ->
        case Map.fetch(@terminal_phase_results, phase) do
          {:ok, result} -> {:ok, %{"result" => result, "outputs" => outputs}}
          :error -> {:error, {:unsatisfied_need, job_id, phase}}
        end
    end
  end

  @spec validate_github_context(term()) ::
          {:ok, GithubContext.t()} | {:error, {:invalid_github_context, term()}}
  defp validate_github_context(%GithubContext{} = context), do: {:ok, context}
  defp validate_github_context(other), do: {:error, {:invalid_github_context, other}}

  @spec validate_env(term(), atom()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, {atom(), term()}}
  defp validate_env(env, error_tag) when is_map(env) do
    if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, env}
    else
      {:error, {error_tag, env}}
    end
  end

  defp validate_env(other, error_tag), do: {:error, {error_tag, other}}

  @spec validate_needs(term()) :: {:ok, [job_id()]} | {:error, {:invalid_needs, term()}}
  defp validate_needs(needs) when is_list(needs) do
    if Enum.all?(needs, &is_binary/1) do
      {:ok, needs}
    else
      {:error, {:invalid_needs, needs}}
    end
  end

  defp validate_needs(other), do: {:error, {:invalid_needs, other}}

  @spec validate_job_statuses(term()) ::
          {:ok, %{optional(job_id()) => JobStatus.t()}}
          | {:error, {:invalid_job_statuses, term()}}
  defp validate_job_statuses(job_statuses) when is_map(job_statuses) do
    if Enum.all?(job_statuses, fn {k, v} -> is_binary(k) and match?(%JobStatus{}, v) end) do
      {:ok, job_statuses}
    else
      {:error, {:invalid_job_statuses, job_statuses}}
    end
  end

  defp validate_job_statuses(other), do: {:error, {:invalid_job_statuses, other}}
end
