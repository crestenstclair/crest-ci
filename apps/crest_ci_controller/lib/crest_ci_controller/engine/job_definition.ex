defmodule CrestCiController.Engine.JobDefinition do
  @moduledoc """
  One job as declared in a GitHub Actions workflow file: its `id`,
  display `name`, `needs` (job ids it depends on), `runsOn` labels, its
  job-level `if:` `condition`, its `env` map, its `steps` (kept in raw
  template form — step-level `${{ }}` expressions are never evaluated
  here, they ship to the runner unevaluated), and its `timeoutMinutes`.

  This is the C1-tier engine's per-job shape (see `spec/engine.cue`,
  `valueObject.Engine.JobDefinition`). Scope is deliberately narrow —
  this value object validates only the job-level fields
  `CrestCiController.Engine.WorkflowParser` extracts from a raw decoded
  job map (`id`, `name`, `needs`, `runs-on`, `if`, `env`, `steps`,
  `timeout-minutes`); it knows nothing about YAML syntax, merge keys,
  or workflow-level shape.

  `steps` stays a `list(map())` of raw decoded step maps — GitHub's own
  split keeps step-level expressions (`run:`, `with:`, ...) unevaluated
  until the runner executes them; only workflow/job-tier scope (job
  `if`, `env` merge, `runs-on`, `needs` references) is this engine's
  concern.

  Pure value object: no processes, no I/O, no clock reads. Identical
  input always produces an identical result.
  """

  defstruct id: nil,
            name: nil,
            needs: [],
            runs_on: [],
            condition: "",
            env: %{},
            steps: [],
            timeout_minutes: 360

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          needs: [String.t()],
          runs_on: [String.t()],
          condition: String.t(),
          env: %{optional(String.t()) => String.t()},
          steps: [map()],
          timeout_minutes: integer()
        }

  @doc """
  Builds a new `JobDefinition` from field values (atom keys).

  `id` and `name` must be binaries. `needs` and `runs_on` must be lists
  of binaries. `condition` must be a binary (empty string means "no
  `if:`" — matching GitHub's own default of always-run). `env` must be
  a map of binary keys to binary values. `steps` must be a list of maps
  (raw, unevaluated template form). `timeout_minutes` must be an
  integer.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(fields) when is_map(fields) do
    with {:ok, id} <- validate_id(Map.get(fields, :id)),
         {:ok, name} <- validate_name(Map.get(fields, :name)),
         {:ok, needs} <- validate_string_list(Map.get(fields, :needs, []), :invalid_needs),
         {:ok, runs_on} <- validate_string_list(Map.get(fields, :runs_on, []), :invalid_runs_on),
         {:ok, condition} <- validate_condition(Map.get(fields, :condition, "")),
         {:ok, env} <- validate_env(Map.get(fields, :env, %{})),
         {:ok, steps} <- validate_steps(Map.get(fields, :steps, [])),
         {:ok, timeout_minutes} <-
           validate_timeout_minutes(Map.get(fields, :timeout_minutes, 360)) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         needs: needs,
         runs_on: runs_on,
         condition: condition,
         env: env,
         steps: steps,
         timeout_minutes: timeout_minutes
       }}
    end
  end

  def new(other), do: {:error, {:invalid_job_definition, other}}

  @doc """
  Decodes a `JobDefinition` from its wire JSON shape: a map with
  camelCase string keys (`id`, `name`, `needs`, `runsOn`, `condition`,
  `env`, `steps`, `timeoutMinutes`) — the shape
  `CrestCiController.Engine.WorkflowParser` builds per job before
  handing it to this module.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    new(%{
      id: Map.get(wire, "id"),
      name: Map.get(wire, "name"),
      needs: Map.get(wire, "needs", []),
      runs_on: Map.get(wire, "runsOn", []),
      condition: Map.get(wire, "condition", ""),
      env: Map.get(wire, "env", %{}),
      steps: Map.get(wire, "steps", []),
      timeout_minutes: Map.get(wire, "timeoutMinutes", 360)
    })
  end

  def from_wire(other), do: {:error, {:invalid_job_definition, other}}

  @doc "Encodes a `JobDefinition` into its wire JSON shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = job) do
    %{
      "id" => job.id,
      "name" => job.name,
      "needs" => job.needs,
      "runsOn" => job.runs_on,
      "condition" => job.condition,
      "env" => job.env,
      "steps" => job.steps,
      "timeoutMinutes" => job.timeout_minutes
    }
  end

  @spec validate_id(term()) :: {:ok, String.t()} | {:error, {:invalid_id, term()}}
  defp validate_id(id) when is_binary(id), do: {:ok, id}
  defp validate_id(other), do: {:error, {:invalid_id, other}}

  @spec validate_name(term()) :: {:ok, String.t()} | {:error, {:invalid_name, term()}}
  defp validate_name(name) when is_binary(name), do: {:ok, name}
  defp validate_name(other), do: {:error, {:invalid_name, other}}

  @spec validate_string_list(term(), atom()) ::
          {:ok, [String.t()]} | {:error, {atom(), term()}}
  defp validate_string_list(list, error_tag) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      {:error, {error_tag, list}}
    end
  end

  defp validate_string_list(other, error_tag), do: {:error, {error_tag, other}}

  @spec validate_condition(term()) :: {:ok, String.t()} | {:error, {:invalid_condition, term()}}
  defp validate_condition(condition) when is_binary(condition), do: {:ok, condition}
  defp validate_condition(other), do: {:error, {:invalid_condition, other}}

  @spec validate_env(term()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, {:invalid_env, term()}}
  defp validate_env(env) when is_map(env) do
    if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, env}
    else
      {:error, {:invalid_env, env}}
    end
  end

  defp validate_env(other), do: {:error, {:invalid_env, other}}

  @spec validate_steps(term()) :: {:ok, [map()]} | {:error, {:invalid_steps, term()}}
  defp validate_steps(steps) when is_list(steps) do
    if Enum.all?(steps, &is_map/1) do
      {:ok, steps}
    else
      {:error, {:invalid_steps, steps}}
    end
  end

  defp validate_steps(other), do: {:error, {:invalid_steps, other}}

  @spec validate_timeout_minutes(term()) ::
          {:ok, integer()} | {:error, {:invalid_timeout_minutes, term()}}
  defp validate_timeout_minutes(minutes) when is_integer(minutes), do: {:ok, minutes}
  defp validate_timeout_minutes(other), do: {:error, {:invalid_timeout_minutes, other}}
end

defimpl Jason.Encoder, for: CrestCiController.Engine.JobDefinition do
  def encode(job, opts) do
    job
    |> CrestCiController.Engine.JobDefinition.to_wire()
    |> Jason.Encode.map(opts)
  end
end
