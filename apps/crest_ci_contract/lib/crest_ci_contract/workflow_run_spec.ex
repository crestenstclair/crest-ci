defmodule CrestCiContract.WorkflowRunSpec do
  @moduledoc """
  `WorkflowRunSpec` is the immutable "what to run" carried by a
  `WorkflowRun` custom resource: the repository/ref/sha being built, an
  optional `concurrencyKey` used to serialize overlapping runs, an
  optional `placement` hint map, and `plan` — the pre-expanded job DAG
  (see `CrestCiContract.PlanJob`).

  The workflow engine that expands a workflow definition file into a
  `plan` lands in a later phase; this slice only carries the already
  -expanded plan through unchanged.

  Pure value object: a plain struct with (de)serialization to/from the
  Kubernetes JSON wire shape (camelCase keys) via `to_wire/1` /
  `from_wire/1`, and via `Jason.Encoder` for direct `Jason.encode!/1`
  calls. There is no I/O and no process state here.
  """

  alias CrestCiContract.PlanJob

  @enforce_keys [:repo, :ref, :sha]
  defstruct concurrency_key: "",
            placement: %{},
            plan: [],
            ref: nil,
            repo: nil,
            sha: nil

  @type t :: %__MODULE__{
          concurrency_key: String.t(),
          placement: map(),
          plan: [PlanJob.t()],
          ref: String.t(),
          repo: String.t(),
          sha: String.t()
        }

  @doc """
  Builds a new `WorkflowRunSpec` from field values (atom keys).

  `repo`, `ref`, and `sha` must be non-empty binaries. `concurrency_key`
  defaults to `""` (no concurrency serialization), `placement` defaults
  to `%{}`, and `plan` defaults to `[]`. Every element of `plan` must
  already be a `PlanJob` struct or a map buildable into one via
  `PlanJob.new/1`. No two `plan` entries may share the same `key` —
  `plan` is a DAG addressed by `JobKey`, so a duplicate key would make
  reconciliation unable to address jobs unambiguously.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(fields) when is_map(fields) do
    with {:ok, repo} <- validate_non_empty_binary(Map.get(fields, :repo), :invalid_repo),
         {:ok, ref} <- validate_non_empty_binary(Map.get(fields, :ref), :invalid_ref),
         {:ok, sha} <- validate_non_empty_binary(Map.get(fields, :sha), :invalid_sha),
         {:ok, concurrency_key} <- validate_binary(Map.get(fields, :concurrency_key, "")),
         {:ok, placement} <- validate_map(Map.get(fields, :placement, %{})),
         {:ok, plan} <- validate_plan(Map.get(fields, :plan, [])) do
      {:ok,
       %__MODULE__{
         concurrency_key: concurrency_key,
         placement: placement,
         plan: plan,
         ref: ref,
         repo: repo,
         sha: sha
       }}
    end
  end

  @doc """
  Decodes a `WorkflowRunSpec` from its Kubernetes JSON wire shape: a map
  with camelCase string keys (`concurrencyKey`, `placement`, `plan`,
  `ref`, `repo`, `sha`). Each element of `plan` is itself decoded from
  its own wire shape via `PlanJob.from_wire/1`.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    with {:ok, plan} <- decode_plan_wire(Map.get(wire, "plan", [])) do
      new(%{
        concurrency_key: Map.get(wire, "concurrencyKey", ""),
        placement: Map.get(wire, "placement", %{}),
        plan: plan,
        ref: Map.get(wire, "ref"),
        repo: Map.get(wire, "repo"),
        sha: Map.get(wire, "sha")
      })
    end
  end

  def from_wire(other), do: {:error, {:invalid_workflow_run_spec, other}}

  @spec decode_plan_wire(term()) :: {:ok, [PlanJob.t()]} | {:error, {:invalid_plan, term()}}
  defp decode_plan_wire(plan) when is_list(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, fn job_wire, {:ok, acc} ->
      case PlanJob.from_wire(job_wire) do
        {:ok, job} -> {:cont, {:ok, [job | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_plan, reason}}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_plan_wire(other), do: {:error, {:invalid_plan, other}}

  @doc "Encodes a `WorkflowRunSpec` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = spec) do
    %{
      "concurrencyKey" => spec.concurrency_key,
      "placement" => spec.placement,
      "plan" => Enum.map(spec.plan, &PlanJob.to_wire/1),
      "ref" => spec.ref,
      "repo" => spec.repo,
      "sha" => spec.sha
    }
  end

  @spec validate_non_empty_binary(term(), atom()) :: {:ok, String.t()} | {:error, atom()}
  defp validate_non_empty_binary(value, _error) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp validate_non_empty_binary(_value, error), do: {:error, error}

  @spec validate_binary(term()) ::
          {:ok, String.t()} | {:error, {:invalid_concurrency_key, term()}}
  defp validate_binary(value) when is_binary(value), do: {:ok, value}
  defp validate_binary(other), do: {:error, {:invalid_concurrency_key, other}}

  @spec validate_map(term()) :: {:ok, map()} | {:error, {:invalid_placement, term()}}
  defp validate_map(value) when is_map(value), do: {:ok, value}
  defp validate_map(other), do: {:error, {:invalid_placement, other}}

  @spec validate_plan(term()) :: {:ok, [PlanJob.t()]} | {:error, {:invalid_plan, term()}}
  defp validate_plan(plan) when is_list(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, fn
      %PlanJob{} = job, {:ok, acc} ->
        {:cont, {:ok, [job | acc]}}

      %{} = job, {:ok, acc} ->
        case PlanJob.new(job) do
          {:ok, built} -> {:cont, {:ok, [built | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_plan, reason}}}
        end

      other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_plan, other}}}
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)} |> reject_duplicate_keys()
      {:error, _reason} = error -> error
    end
  end

  defp validate_plan(other), do: {:error, {:invalid_plan, other}}

  @spec reject_duplicate_keys({:ok, [PlanJob.t()]}) ::
          {:ok, [PlanJob.t()]} | {:error, {:invalid_plan, {:duplicate_job_key, String.t()}}}
  defp reject_duplicate_keys({:ok, jobs} = ok) do
    case find_duplicate_key(jobs, MapSet.new()) do
      nil -> ok
      key -> {:error, {:invalid_plan, {:duplicate_job_key, key}}}
    end
  end

  @spec find_duplicate_key([PlanJob.t()], MapSet.t()) :: String.t() | nil
  defp find_duplicate_key([], _seen), do: nil

  defp find_duplicate_key([%PlanJob{key: key} | rest], seen) do
    if MapSet.member?(seen, key) do
      key
    else
      find_duplicate_key(rest, MapSet.put(seen, key))
    end
  end
end

defimpl Jason.Encoder, for: CrestCiContract.WorkflowRunSpec do
  def encode(spec, opts) do
    spec
    |> CrestCiContract.WorkflowRunSpec.to_wire()
    |> Jason.Encode.map(opts)
  end
end
