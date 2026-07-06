defmodule CrestCiContract.PlanJob do
  @moduledoc """
  One node of the expanded job DAG carried in `WorkflowRunSpec.plan`.

  A `WorkflowRun`'s `plan` is hand-planned in this slice (the workflow
  engine that expands a workflow definition into a DAG lands in a later
  phase) — but the shape of a single planned job is stable: a `key`
  identifying its path in the plan, the `needs` edges to other jobs it
  depends on, the `runsOn` labels used to match a runner, and the raw
  `steps` to execute.

  `key` and each element of `needs` are `CrestCiContract.JobKey` values —
  plain strings identifying a job's path within the plan (see
  `CrestCiContract.JobKey` for the slugging rules used to derive
  Kubernetes-name-safe fragments from them).

  `needs` describes the *edges* of the job DAG, so it must itself be
  well-formed as a set of edges: a job cannot depend on itself (that
  would be a zero-length cycle) and cannot list the same dependency
  twice (that would silently double-count an edge during DAG
  construction). Both are rejected by `new/1` and `from_wire/1`.

  `steps` is a list of plain maps — this value object does not interpret
  step contents (that belongs to whatever context executes them); it only
  carries them through unchanged.

  Pure value object: a plain struct with (de)serialization to/from the
  Kubernetes JSON wire shape (camelCase keys) via `to_wire/1` / `from_wire/1`,
  and via `Jason.Encoder` for direct `Jason.encode!/1` calls. There is no
  I/O and no process state here.
  """

  alias CrestCiContract.JobKey

  @enforce_keys [:key]
  defstruct display_name: "",
            key: nil,
            needs: [],
            runs_on: [],
            steps: []

  @type t :: %__MODULE__{
          display_name: String.t(),
          key: JobKey.t(),
          needs: [JobKey.t()],
          runs_on: [String.t()],
          steps: [map()]
        }

  @doc """
  Builds a new `PlanJob` from field values (atom keys).

  `key` must be a valid `JobKey` (a non-empty binary); every element of
  `needs` must also be a valid `JobKey`, must not equal `key` itself (a
  job cannot depend on itself), and must not repeat (no duplicate
  edges). `runs_on` must be a list of binaries and `steps` a list of
  maps.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(fields) when is_map(fields) do
    with {:ok, key} <- JobKey.new(Map.get(fields, :key)),
         {:ok, needs} <- validate_needs(Map.get(fields, :needs, []), key),
         {:ok, runs_on} <- validate_runs_on(Map.get(fields, :runs_on, [])),
         {:ok, steps} <- validate_steps(Map.get(fields, :steps, [])) do
      {:ok,
       %__MODULE__{
         display_name: Map.get(fields, :display_name, ""),
         key: key,
         needs: needs,
         runs_on: runs_on,
         steps: steps
       }}
    end
  end

  @doc """
  Decodes a `PlanJob` from its Kubernetes JSON wire shape: a map with
  camelCase string keys (`displayName`, `key`, `needs`, `runsOn`, `steps`).
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    new(%{
      display_name: Map.get(wire, "displayName", ""),
      key: Map.get(wire, "key"),
      needs: Map.get(wire, "needs", []),
      runs_on: Map.get(wire, "runsOn", []),
      steps: Map.get(wire, "steps", [])
    })
  end

  @doc "Encodes a `PlanJob` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = plan_job) do
    %{
      "displayName" => plan_job.display_name,
      "key" => plan_job.key,
      "needs" => plan_job.needs,
      "runsOn" => plan_job.runs_on,
      "steps" => plan_job.steps
    }
  end

  @spec validate_needs(term(), JobKey.t()) ::
          {:ok, [JobKey.t()]} | {:error, {:invalid_needs, term()}}
  defp validate_needs(needs, key) when is_list(needs) do
    cond do
      not Enum.all?(needs, &(is_binary(&1) and byte_size(&1) > 0)) ->
        {:error, {:invalid_needs, needs}}

      Enum.any?(needs, &(&1 == key)) ->
        {:error, {:invalid_needs, needs}}

      Enum.uniq(needs) != needs ->
        {:error, {:invalid_needs, needs}}

      true ->
        {:ok, needs}
    end
  end

  defp validate_needs(other, _key), do: {:error, {:invalid_needs, other}}

  @spec validate_runs_on(term()) :: {:ok, [String.t()]} | {:error, {:invalid_runs_on, term()}}
  defp validate_runs_on(runs_on) when is_list(runs_on) do
    if Enum.all?(runs_on, &is_binary/1) do
      {:ok, runs_on}
    else
      {:error, {:invalid_runs_on, runs_on}}
    end
  end

  defp validate_runs_on(other), do: {:error, {:invalid_runs_on, other}}

  @spec validate_steps(term()) :: {:ok, [map()]} | {:error, {:invalid_steps, term()}}
  defp validate_steps(steps) when is_list(steps) do
    if Enum.all?(steps, &is_map/1) do
      {:ok, steps}
    else
      {:error, {:invalid_steps, steps}}
    end
  end

  defp validate_steps(other), do: {:error, {:invalid_steps, other}}
end

defimpl Jason.Encoder, for: CrestCiContract.PlanJob do
  def encode(plan_job, opts) do
    plan_job
    |> CrestCiContract.PlanJob.to_wire()
    |> Jason.Encode.map(opts)
  end
end
