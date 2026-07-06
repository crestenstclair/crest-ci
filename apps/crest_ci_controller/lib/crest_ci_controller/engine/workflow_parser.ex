defmodule CrestCiController.Engine.WorkflowParser do
  @moduledoc """
  Pure YAML -> IR parser for one GitHub Actions workflow file.

  `parse/1` takes the raw YAML text of a workflow file and returns
  `{:ok, WorkflowDefinition, warnings}` on success, or `{:error, reason}`
  when the document cannot be turned into a workflow at all.

  Scope (see `spec/engine.cue`, `domainService.Engine.WorkflowParser`):

    * YAML anchors are resolved by the underlying YAML decoder.
    * YAML merge keys (`<<: *anchor`, `<<: [*a, *b]`) are NOT resolved by
      the decoder (`yamerl`/`YamlElixir` decode them as a literal `"<<"`
      key holding the referenced map/list) — this module resolves them
      itself, honoring the YAML merge-key semantics: explicit keys in a
      mapping always win over anything pulled in via `<<`, and when `<<`
      is a sequence, earlier entries in the sequence win over later ones
      on conflict (http://yaml.org/type/merge.html).
    * GitHub's `on:` shorthand forms are normalized to the map shape
      `WorkflowDefinition` requires: a bare string (`on: push`) becomes
      `%{"push" => %{}}` and a list of strings (`on: [push, pull_request]`)
      becomes `%{"push" => %{}, "pull_request" => %{}}`. An already-mapped
      `on:` (`on: {push: {branches: [...]}}`) passes through untouched.
    * Unknown top-level keys (delegated to `WorkflowDefinition.from_decoded/2`)
      and unknown job-level keys (handled here) are never errors — each
      becomes an `{:unknown_key, key_path}` warning, matching GitHub's own
      tolerance of keys it doesn't recognize.
    * Step-level expressions (`${{ }}` inside a step's `run`/`with`/...)
      are never touched — they ship to the runner in template form. Only
      workflow/job-level shape is validated here: job `if`, `env`,
      `runs-on`, `needs`, `name`, `timeout-minutes`.

  Pure function: no processes, no I/O beyond the YAML decode of the given
  string, no clock reads. Identical input always produces an identical
  result.
  """

  alias CrestCiController.Engine.WorkflowDefinition
  alias CrestCiController.Engine.JobDefinition

  @type warning :: {:unknown_key, String.t()}

  @known_job_keys ~w(name needs runs-on if env steps timeout-minutes)
  @merge_key_pattern ~r/^<<\d*$/

  @doc """
  Parses raw workflow YAML text into a `WorkflowDefinition`.

  Returns `{:ok, definition, warnings}` when the document is structurally
  valid (known keys are well-formed; unknown keys are reported as
  warnings, not errors). Returns `{:error, reason}` for YAML syntax
  errors, a non-mapping document, or a malformed known key (workflow- or
  job-level).
  """
  @spec parse(String.t()) :: {:ok, WorkflowDefinition.t(), [warning()]} | {:error, term()}
  def parse(yaml) when is_binary(yaml) do
    with {:ok, decoded} <- decode_yaml(yaml),
         {:ok, document} <- ensure_map(decoded),
         resolved <- document |> resolve_merge_keys() |> normalize_on(),
         {:ok, definition, workflow_warnings} <- WorkflowDefinition.from_decoded(resolved, yaml),
         {:ok, job_warnings} <- validate_jobs(definition.jobs) do
      {:ok, definition, workflow_warnings ++ job_warnings}
    end
  end

  def parse(other), do: {:error, {:invalid_yaml_input, other}}

  # -- YAML decode -----------------------------------------------------

  @spec decode_yaml(String.t()) :: {:ok, term()} | {:error, {:yaml_syntax_error, String.t()}}
  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:yaml_syntax_error, format_reason(reason)}}
    end
  rescue
    exception -> {:error, {:yaml_syntax_error, Exception.message(exception)}}
  end

  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)

  @spec ensure_map(term()) :: {:ok, map()} | {:error, {:invalid_workflow_document, term()}}
  defp ensure_map(%{} = document), do: {:ok, document}
  defp ensure_map(other), do: {:error, {:invalid_workflow_document, other}}

  # -- YAML merge-key resolution ----------------------------------------

  @spec resolve_merge_keys(term()) :: term()
  defp resolve_merge_keys(%{} = map) do
    resolved_children =
      Map.new(map, fn {key, value} -> {key, resolve_merge_keys(value)} end)

    {merge_entries, explicit_entries} =
      Enum.split_with(resolved_children, fn {key, _value} -> merge_key?(key) end)

    merge_base =
      merge_entries
      |> Enum.flat_map(fn {_key, value} -> List.wrap(value) end)
      |> Enum.reduce(%{}, fn source, acc ->
        # Earlier entries in a `<<: [a, b, ...]` sequence win on conflict.
        Map.merge(source, acc)
      end)

    Map.merge(merge_base, Map.new(explicit_entries))
  end

  defp resolve_merge_keys(list) when is_list(list), do: Enum.map(list, &resolve_merge_keys/1)
  defp resolve_merge_keys(other), do: other

  @spec merge_key?(term()) :: boolean()
  defp merge_key?(key) when is_binary(key), do: Regex.match?(@merge_key_pattern, key)
  defp merge_key?(_key), do: false

  # -- `on:` shorthand normalization --------------------------------------

  # GitHub accepts `on:` as a bare event name, a list of event names, or a
  # map of event name -> filter config. `WorkflowDefinition` only accepts
  # the map form, so the scalar/list shorthands are normalized here.
  @spec normalize_on(map()) :: map()
  defp normalize_on(%{"on" => on} = document), do: Map.put(document, "on", normalize_on_value(on))
  defp normalize_on(document), do: document

  @spec normalize_on_value(term()) :: term()
  defp normalize_on_value(on) when is_map(on), do: on
  defp normalize_on_value(on) when is_binary(on), do: %{on => %{}}

  defp normalize_on_value(on) when is_list(on) do
    if Enum.all?(on, &is_binary/1) do
      Map.new(on, &{&1, %{}})
    else
      on
    end
  end

  defp normalize_on_value(on), do: on

  # -- job-level validation ----------------------------------------------

  @spec validate_jobs(%{optional(String.t()) => map()}) ::
          {:ok, [warning()]} | {:error, term()}
  defp validate_jobs(jobs) do
    jobs
    |> Enum.sort_by(fn {job_id, _raw_job} -> job_id end)
    |> Enum.reduce_while({:ok, []}, fn {job_id, raw_job}, {:ok, warnings_acc} ->
      case build_job(job_id, raw_job) do
        {:ok, _job_definition, job_warnings} -> {:cont, {:ok, warnings_acc ++ job_warnings}}
        {:error, reason} -> {:halt, {:error, {:invalid_job, job_id, reason}}}
      end
    end)
  end

  @spec build_job(String.t(), term()) ::
          {:ok, JobDefinition.t(), [warning()]} | {:error, term()}
  defp build_job(job_id, raw_job) when is_map(raw_job) do
    warnings =
      raw_job
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_job_keys))
      |> Enum.sort()
      |> Enum.map(&{:unknown_key, "jobs.#{job_id}.#{&1}"})

    wire = %{
      "id" => job_id,
      "name" => Map.get(raw_job, "name", job_id),
      "needs" => normalize_list(Map.get(raw_job, "needs", [])),
      "runsOn" => normalize_list(Map.get(raw_job, "runs-on", [])),
      "condition" => Map.get(raw_job, "if", ""),
      "env" => Map.get(raw_job, "env", %{}),
      "steps" => Map.get(raw_job, "steps", []),
      "timeoutMinutes" => Map.get(raw_job, "timeout-minutes", 360)
    }

    case JobDefinition.from_wire(wire) do
      {:ok, job_definition} -> {:ok, job_definition, warnings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_job(job_id, other), do: {:error, {:invalid_job_shape, job_id, other}}

  @spec normalize_list(term()) :: list()
  defp normalize_list(nil), do: []
  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(value), do: [value]
end
