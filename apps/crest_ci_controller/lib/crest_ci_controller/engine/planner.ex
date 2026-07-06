defmodule CrestCiController.Engine.Planner do
  @moduledoc """
  Pure domain service: expands one parsed `WorkflowDefinition`, together
  with the trigger's `GithubContext`, into the ordered `PlanJob` DAG a
  `WorkflowRun` carries as its `plan`.

  `plan/2` is the engine's single entry point:

    * validates the `needs` DAG declared across all jobs — a `needs`
      reference to a job id that does not exist in the workflow, or a
      dependency cycle, is reported as a structured `{:error, _}` naming
      every offending job id, never a crash;
    * evaluates each job's `if:` condition (defaulting to `true` when
      absent, matching GitHub's own default) against the workflow/job
      tier context `CrestCiController.Engine.ContextAssembler` builds —
      a job whose condition evaluates falsy is excluded from the plan
      entirely (skipped-at-plan-time by omission, not by a `PlanJob`
      carrying a skipped marker);
    * interpolates each `runs-on:` label that is itself a whole `${{ }}`
      expression against that same context (`runs-on: [ubuntu-latest]`
      passes through untouched; `runs-on: ${{ env.RUNNER }}` resolves to
      the evaluated value, stringified); a non-string `runs-on:` entry
      (a malformed workflow) is passed through untouched and left for
      `PlanJob.new/1`'s own validation to reject;
    * emits the surviving jobs' `PlanJob`s in a deterministic, stable
      order: topological over `needs`, with ties between jobs that
      become ready at the same point broken lexicographically by job
      id (Kahn's algorithm, picking the lexicographically smallest
      ready job id at each step).

  This C1 slice deliberately has no `needs` *outcomes* to consult — no
  job has run yet at plan time — so every job's expression context is
  assembled with an empty `needs` branch (`ContextAssembler.build/1`
  called with `needs: []` and `job_statuses: %{}`, regardless of what
  the job itself declares in `needs:`). `success()` is therefore
  trivially true (an empty needs map vacuously satisfies it, mirroring
  GitHub's own default job condition for a job with no dependencies),
  `failure()`/`cancelled()` are false, and a literal `needs.<job>.*`
  reference resolves to `nil` — a job-level `if:` that depends on a
  sibling's actual runtime outcome is a step/runtime-tier concern this
  static planner does not attempt to predict. Only `github.*` and
  `env.*` references carry real information here, which is exactly what
  the golden fixtures exercise.

  Pure function module: no processes, no I/O, no clock reads. Identical
  `(WorkflowDefinition, GithubContext)` input always produces a
  byte-identical result (or byte-identical error) — this is the
  engine's central determinism invariant.
  """

  alias CrestCiController.Engine.ContextAssembler
  alias CrestCiController.Engine.ExpressionEvaluator
  alias CrestCiController.Engine.GithubContext
  alias CrestCiController.Engine.WorkflowDefinition
  alias CrestCiContract.PlanJob

  @type job_id :: String.t()

  @type unknown_need :: %{job_id: job_id(), target: job_id()}

  @type plan_error ::
          {:unknown_needs, [unknown_need()]}
          | {:cyclic_needs, [job_id()]}
          | {:invalid_context, job_id(), term()}
          | {:invalid_condition, job_id(), term()}
          | {:invalid_runs_on, job_id(), term()}
          | {:invalid_plan_job, job_id(), term()}
          | {:invalid_input, term()}

  @typep job_spec :: %{
           name: String.t(),
           needs: [job_id()],
           runs_on: [term()],
           condition: String.t(),
           env: map(),
           steps: [map()]
         }

  @doc """
  Expands `definition` into its ordered `PlanJob` list for the trigger
  described by `github_context`.

  Returns `{:ok, plan_jobs}` — `plan_jobs` excludes every job whose
  `if:` evaluated falsy, in deterministic topological/lexicographic
  order — or `{:error, plan_error}` when the `needs` DAG is malformed,
  or a job's assembled context, `if:`, or `runs-on:` fails to resolve.
  """
  @spec plan(WorkflowDefinition.t(), GithubContext.t()) ::
          {:ok, [PlanJob.t()]} | {:error, plan_error()}
  def plan(%WorkflowDefinition{jobs: jobs, env: workflow_env}, %GithubContext{} = github_context) do
    job_specs = build_job_specs(jobs)

    with :ok <- validate_needs_targets(job_specs),
         {:ok, order} <- topological_order(job_specs) do
      build_plan(order, job_specs, workflow_env, github_context)
    end
  end

  def plan(other_definition, other_context),
    do: {:error, {:invalid_input, {other_definition, other_context}}}

  # -- Per-job spec extraction (raw decoded job maps -> normalized fields) --

  @spec build_job_specs(%{optional(job_id()) => map()}) :: %{optional(job_id()) => job_spec()}
  defp build_job_specs(jobs) do
    Map.new(jobs, fn {job_id, raw_job} -> {job_id, build_job_spec(job_id, raw_job)} end)
  end

  @spec build_job_spec(job_id(), map()) :: job_spec()
  defp build_job_spec(job_id, raw_job) do
    %{
      name: Map.get(raw_job, "name") || job_id,
      needs: raw_job |> Map.get("needs") |> normalize_list() |> Enum.uniq(),
      runs_on: raw_job |> Map.get("runs-on") |> normalize_list(),
      condition: normalize_condition(Map.get(raw_job, "if")),
      env: Map.get(raw_job, "env") || %{},
      steps: Map.get(raw_job, "steps") || []
    }
  end

  @spec normalize_list(term()) :: list()
  defp normalize_list(nil), do: []
  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(value), do: [value]

  @spec normalize_condition(term()) :: String.t()
  defp normalize_condition(nil), do: ""
  defp normalize_condition(condition) when is_binary(condition), do: condition

  defp normalize_condition(condition) when is_boolean(condition) or is_number(condition),
    do: to_string(condition)

  defp normalize_condition(_other), do: ""

  # -- needs DAG validation: unknown targets ------------------------------

  @spec validate_needs_targets(%{optional(job_id()) => job_spec()}) ::
          :ok | {:error, {:unknown_needs, [unknown_need()]}}
  defp validate_needs_targets(job_specs) do
    known = MapSet.new(Map.keys(job_specs))

    offenses =
      for {job_id, %{needs: needs}} <- job_specs,
          target <- needs,
          not MapSet.member?(known, target) do
        %{job_id: job_id, target: target}
      end

    offenses = Enum.sort_by(offenses, &{&1.job_id, &1.target})

    if offenses == [] do
      :ok
    else
      {:error, {:unknown_needs, offenses}}
    end
  end

  # -- needs DAG topological order: Kahn's algorithm with lexicographic --
  # -- tie-break on the ready set — leftover nodes name a cycle ----------

  @spec topological_order(%{optional(job_id()) => job_spec()}) ::
          {:ok, [job_id()]} | {:error, {:cyclic_needs, [job_id()]}}
  defp topological_order(job_specs) do
    remaining = Map.new(job_specs, fn {job_id, spec} -> {job_id, MapSet.new(spec.needs)} end)
    kahn(remaining, [])
  end

  @spec kahn(%{optional(job_id()) => MapSet.t()}, [job_id()]) ::
          {:ok, [job_id()]} | {:error, {:cyclic_needs, [job_id()]}}
  defp kahn(remaining, order) when map_size(remaining) == 0, do: {:ok, Enum.reverse(order)}

  defp kahn(remaining, order) do
    ready =
      remaining
      |> Enum.filter(fn {_job_id, needs} -> MapSet.size(needs) == 0 end)
      |> Enum.map(fn {job_id, _needs} -> job_id end)
      |> Enum.sort()

    case ready do
      [] ->
        {:error, {:cyclic_needs, remaining |> Map.keys() |> Enum.sort()}}

      [next | _rest] ->
        remaining
        |> Map.delete(next)
        |> Map.new(fn {job_id, needs} -> {job_id, MapSet.delete(needs, next)} end)
        |> kahn([next | order])
    end
  end

  # -- Build the surviving PlanJobs, in order -----------------------------

  @spec build_plan(
          [job_id()],
          %{optional(job_id()) => job_spec()},
          %{optional(String.t()) => String.t()},
          GithubContext.t()
        ) :: {:ok, [PlanJob.t()]} | {:error, plan_error()}
  defp build_plan(order, job_specs, workflow_env, github_context) do
    result =
      Enum.reduce_while(order, {:ok, []}, fn job_id, {:ok, acc} ->
        spec = Map.fetch!(job_specs, job_id)

        case plan_job(job_id, spec, workflow_env, github_context) do
          {:ok, :excluded} -> {:cont, {:ok, acc}}
          {:ok, plan_job} -> {:cont, {:ok, [plan_job | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  @spec plan_job(job_id(), job_spec(), map(), GithubContext.t()) ::
          {:ok, PlanJob.t() | :excluded} | {:error, plan_error()}
  defp plan_job(job_id, spec, workflow_env, github_context) do
    with {:ok, context} <- assemble_context(job_id, spec, workflow_env, github_context),
         {:ok, included?} <- evaluate_condition(job_id, spec.condition, context) do
      if included? do
        with {:ok, runs_on} <- interpolate_runs_on(job_id, spec.runs_on, context) do
          build_plan_job(job_id, spec, runs_on)
        end
      else
        {:ok, :excluded}
      end
    end
  end

  @spec assemble_context(job_id(), job_spec(), map(), GithubContext.t()) ::
          {:ok, map()} | {:error, plan_error()}
  defp assemble_context(job_id, spec, workflow_env, github_context) do
    case ContextAssembler.build(%{
           github_context: github_context,
           workflow_env: workflow_env,
           job_env: spec.env,
           needs: [],
           job_statuses: %{}
         }) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:invalid_context, job_id, reason}}
    end
  end

  @spec evaluate_condition(job_id(), String.t(), map()) ::
          {:ok, boolean()} | {:error, plan_error()}
  defp evaluate_condition(_job_id, "", _context), do: {:ok, true}

  defp evaluate_condition(job_id, condition, context) do
    case ExpressionEvaluator.evaluate(condition, context) do
      {:ok, value} -> {:ok, truthy?(value)}
      {:error, reason} -> {:error, {:invalid_condition, job_id, reason}}
    end
  end

  # GitHub's ToBoolean coercion for the outer if-value: nil/false/0/""
  # are falsy, everything else truthy. Kept local (mirroring
  # ExpressionEvaluator's own choice to keep its coercion table
  # self-contained) since this is the only other place in the engine
  # that needs to collapse an expression result to a plan/skip decision.
  @spec truthy?(term()) :: boolean()
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(n) when is_number(n), do: n != 0
  defp truthy?(s) when is_binary(s), do: s != ""
  defp truthy?(_other), do: true

  @spec interpolate_runs_on(job_id(), [term()], map()) ::
          {:ok, [String.t()]} | {:error, plan_error()}
  defp interpolate_runs_on(job_id, runs_on, context) do
    result =
      Enum.reduce_while(runs_on, {:ok, []}, fn label, {:ok, acc} ->
        case interpolate_label(label, context) do
          {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_runs_on, job_id, reason}}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # A non-binary `runs-on` entry (a malformed workflow) passes through
  # untouched — `PlanJob.new/1`'s own `runs_on` validation rejects it as
  # a structured error, so this never needs to raise.
  @spec interpolate_label(term(), map()) :: {:ok, term()} | {:error, term()}
  defp interpolate_label(label, _context) when not is_binary(label), do: {:ok, label}

  defp interpolate_label(label, context) do
    trimmed = String.trim(label)

    if whole_expression?(trimmed) do
      case ExpressionEvaluator.evaluate(trimmed, context) do
        {:ok, value} -> {:ok, display_string(value)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, label}
    end
  end

  @spec whole_expression?(String.t()) :: boolean()
  defp whole_expression?(s), do: String.starts_with?(s, "${{") and String.ends_with?(s, "}}")

  @spec display_string(term()) :: String.t()
  defp display_string(nil), do: ""
  defp display_string(true), do: "true"
  defp display_string(false), do: "false"
  defp display_string(n) when is_integer(n), do: Integer.to_string(n)

  defp display_string(n) when is_float(n) do
    if n == Float.round(n, 0) do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end

  defp display_string(s) when is_binary(s), do: s
  defp display_string(other), do: Jason.encode!(other)

  @spec build_plan_job(job_id(), job_spec(), [String.t()]) ::
          {:ok, PlanJob.t()} | {:error, plan_error()}
  defp build_plan_job(job_id, spec, runs_on) do
    case PlanJob.new(%{
           display_name: spec.name,
           key: job_id,
           needs: spec.needs,
           runs_on: runs_on,
           steps: spec.steps
         }) do
      {:ok, plan_job} -> {:ok, plan_job}
      {:error, reason} -> {:error, {:invalid_plan_job, job_id, reason}}
    end
  end
end
