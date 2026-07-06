defmodule CrestCiController.Engine.WorkflowDefinition do
  @moduledoc """
  The parsed intermediate representation (IR) of one GitHub Actions
  workflow file: its declared `name`, the raw `on` trigger block, the
  workflow-level `env`, its `jobs`, and the original `rawYaml` the IR
  was derived from.

  This is the C1-tier engine's entry-point shape (see `spec/engine.cue`):
  `name` / `on` / `env` / `jobs` / `rawYaml`. Scope is deliberately
  narrow — this module knows nothing about YAML syntax itself. It
  consumes an already-decoded generic map (string keys, as produced by
  any YAML/JSON decoder) via `from_decoded/2`, plus the original raw
  text for provenance. Turning YAML text into that decoded map is the
  job of `CrestCiController.Engine.WorkflowParser`, not this value
  object.

  `jobs` is kept here as a plain `map<string, map()>` — each job's raw
  decoded body, keyed by job id — rather than a map of already-built
  `CrestCiController.Engine.JobDefinition` structs. Promoting a job's
  raw map into a validated `JobDefinition` is itself a fallible,
  job-shape-aware operation (see that module); this value object only
  guarantees the *workflow-level* shape (`name`, `on`, `env`, `jobs`,
  `rawYaml`) and defers per-job validation to whatever composes the two.

  GitHub tolerates unknown top-level workflow keys (e.g. `permissions`,
  `defaults`, `run-name`, `concurrency` — not modeled in this C1 slice)
  and so do we: `from_decoded/2` never rejects a workflow for carrying
  keys outside `name` / `on` / `env` / `jobs`. Instead it returns those
  key names as warnings alongside the successfully-built definition,
  matching the resource description: "unknown keys are retained as
  warnings, never errors."

  Pure value object: no processes, no I/O, no clock reads. Identical
  input always produces an identical result.
  """

  @known_top_level_keys ~w(name on env jobs)

  defstruct name: nil,
            on: %{},
            env: %{},
            jobs: %{},
            raw_yaml: ""

  @type job_id :: String.t()

  @type t :: %__MODULE__{
          name: String.t() | nil,
          on: map(),
          env: %{optional(String.t()) => String.t()},
          jobs: %{optional(job_id()) => map()},
          raw_yaml: String.t()
        }

  @type warning :: {:unknown_key, String.t()}

  @doc """
  Builds a new `WorkflowDefinition` from field values (atom keys).

  `name` must be a binary or `nil` (a workflow may omit `name:` — GitHub
  falls back to deriving one from the file path, which is out of scope
  here). `on` must be a map (its shape varies by trigger and is not
  further constrained at this tier). `env` must be a map of binary keys
  to binary values. `jobs` must be a map of binary job ids to job maps.
  `raw_yaml` must be a binary.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(fields) when is_map(fields) do
    with {:ok, name} <- validate_name(Map.get(fields, :name)),
         {:ok, on} <- validate_on(Map.get(fields, :on, %{})),
         {:ok, env} <- validate_env(Map.get(fields, :env, %{})),
         {:ok, jobs} <- validate_jobs(Map.get(fields, :jobs, %{})),
         {:ok, raw_yaml} <- validate_raw_yaml(Map.get(fields, :raw_yaml, "")) do
      {:ok,
       %__MODULE__{
         name: name,
         on: on,
         env: env,
         jobs: jobs,
         raw_yaml: raw_yaml
       }}
    end
  end

  def new(other), do: {:error, {:invalid_workflow_definition, other}}

  @doc """
  Builds a `WorkflowDefinition` from an already-decoded workflow map
  (string keys, as produced by a YAML/JSON decoder) plus the original
  raw YAML text.

  Known top-level keys (`"name"`, `"on"`, `"env"`, `"jobs"`) are
  extracted and validated via `new/1`. Every other top-level key is
  never treated as an error — each is instead surfaced as an
  `{:unknown_key, key}` warning in the returned warnings list, and the
  definition still builds successfully.

  Returns `{:ok, t(), [warning()]}` when the known keys are
  well-formed, or `{:error, reason}` when one of them is not (a
  malformed *known* key is a genuine structural error — GitHub would
  reject it too — distinct from an *unknown* key, which is tolerated).
  """
  @spec from_decoded(map(), String.t()) :: {:ok, t(), [warning()]} | {:error, term()}
  def from_decoded(%{} = decoded, raw_yaml) when is_binary(raw_yaml) do
    warnings =
      decoded
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_top_level_keys))
      |> Enum.sort()
      |> Enum.map(&{:unknown_key, &1})

    fields = %{
      name: Map.get(decoded, "name"),
      on: Map.get(decoded, "on", %{}),
      env: Map.get(decoded, "env", %{}),
      jobs: Map.get(decoded, "jobs", %{}),
      raw_yaml: raw_yaml
    }

    case new(fields) do
      {:ok, definition} -> {:ok, definition, warnings}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_decoded(other, _raw_yaml), do: {:error, {:invalid_workflow_definition, other}}

  @doc """
  Decodes a `WorkflowDefinition` from its Kubernetes/wire JSON shape: a
  map with camelCase string keys (`name`, `on`, `env`, `jobs`,
  `rawYaml`).
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    new(%{
      name: Map.get(wire, "name"),
      on: Map.get(wire, "on", %{}),
      env: Map.get(wire, "env", %{}),
      jobs: Map.get(wire, "jobs", %{}),
      raw_yaml: Map.get(wire, "rawYaml", "")
    })
  end

  def from_wire(other), do: {:error, {:invalid_workflow_definition, other}}

  @doc "Encodes a `WorkflowDefinition` into its wire JSON shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = definition) do
    %{
      "name" => definition.name,
      "on" => definition.on,
      "env" => definition.env,
      "jobs" => definition.jobs,
      "rawYaml" => definition.raw_yaml
    }
  end

  @spec validate_name(term()) :: {:ok, String.t() | nil} | {:error, {:invalid_name, term()}}
  defp validate_name(nil), do: {:ok, nil}
  defp validate_name(name) when is_binary(name), do: {:ok, name}
  defp validate_name(other), do: {:error, {:invalid_name, other}}

  @spec validate_on(term()) :: {:ok, map()} | {:error, {:invalid_on, term()}}
  defp validate_on(on) when is_map(on), do: {:ok, on}
  defp validate_on(other), do: {:error, {:invalid_on, other}}

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

  @spec validate_jobs(term()) ::
          {:ok, %{optional(job_id()) => map()}} | {:error, {:invalid_jobs, term()}}
  defp validate_jobs(jobs) when is_map(jobs) do
    if Enum.all?(jobs, fn {k, v} -> is_binary(k) and is_map(v) end) do
      {:ok, jobs}
    else
      {:error, {:invalid_jobs, jobs}}
    end
  end

  defp validate_jobs(other), do: {:error, {:invalid_jobs, other}}

  @spec validate_raw_yaml(term()) :: {:ok, String.t()} | {:error, {:invalid_raw_yaml, term()}}
  defp validate_raw_yaml(raw_yaml) when is_binary(raw_yaml), do: {:ok, raw_yaml}
  defp validate_raw_yaml(other), do: {:error, {:invalid_raw_yaml, other}}
end

defimpl Jason.Encoder, for: CrestCiController.Engine.WorkflowDefinition do
  def encode(definition, opts) do
    definition
    |> CrestCiController.Engine.WorkflowDefinition.to_wire()
    |> Jason.Encode.map(opts)
  end
end
