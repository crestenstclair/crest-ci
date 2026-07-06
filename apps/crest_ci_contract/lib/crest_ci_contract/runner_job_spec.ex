defmodule CrestCiContract.RunnerJobSpec do
  @moduledoc """
  `RunnerJobSpec` is the queue element spec carried on a `RunnerJob` custom
  resource's `spec` field — the immutable payload a runner needs to execute
  one job.

  `job_key` identifies the job's path within its parent `WorkflowRunSpec`
  plan (see `CrestCiContract.JobKey`); `job_message` carries the rendered
  protocol job payload (steps, env, etc.) the runner will actually execute,
  already rendered by the controller from the plan and thus opaque to this
  struct; `run_ref` is the parent run's identifier (e.g. `WorkflowRunSpec.ref`
  or the run ULID, depending on caller); `runs_on` is the label-selector-style
  placement the gateway used to route this job to a matching runner pool —
  it must be a non-empty list of runner labels: a `RunnerJobSpec` with no
  placement information is not a value this type can represent, so every
  construction path rejects it.

  This struct only describes the spec — never the arbitration state.
  `CrestCiContract.RunnerJobSpec` is written once at creation (deterministic
  child name derived from run ULID + job key, per the "409 AlreadyExists is
  success" reconciliation rule) and never mutated after; all
  acquire/lease/complete state lives on `RunnerJobStatus` instead, updated
  only through the status subresource under optimistic concurrency.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1`, and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls.
  """

  alias CrestCiContract.JobKey

  @type t :: %__MODULE__{
          job_key: JobKey.t(),
          job_message: map(),
          run_ref: String.t(),
          runs_on: [String.t(), ...]
        }

  @enforce_keys [:job_key, :run_ref]
  defstruct job_key: nil,
            job_message: %{},
            run_ref: nil,
            runs_on: []

  @doc """
  Builds a new `RunnerJobSpec` from field values (atom keys).

  `job_key` must be a valid `JobKey` (non-empty binary); `run_ref` must be a
  non-empty binary; `runs_on` must be a non-empty list of binaries — an
  empty, `nil`, or missing `runs_on` is rejected, since a `RunnerJobSpec`
  with no placement is not a representable value; `job_message` (defaults to
  `%{}`) must be a map — its internal shape is the rendered protocol payload
  and is intentionally opaque to this module.
  """
  @spec new(map()) ::
          {:ok, t()}
          | {:error,
             :invalid_job_key | :invalid_run_ref | :invalid_runs_on | :invalid_job_message}
  def new(fields) when is_map(fields) do
    job_key = Map.get(fields, :job_key)
    run_ref = Map.get(fields, :run_ref)
    runs_on = Map.get(fields, :runs_on, [])
    job_message = Map.get(fields, :job_message, %{})

    with :ok <- validate_job_key(job_key),
         :ok <- validate_run_ref(run_ref),
         :ok <- validate_runs_on(runs_on),
         :ok <- validate_job_message(job_message) do
      {:ok,
       %__MODULE__{
         job_key: job_key,
         job_message: job_message,
         run_ref: run_ref,
         runs_on: runs_on
       }}
    end
  end

  @doc """
  Decodes a `RunnerJobSpec` from its Kubernetes JSON wire shape: a map with
  camelCase string keys (`jobKey`, `jobMessage`, `runRef`, `runsOn`).

  A missing or empty `runsOn` is rejected, same as in `new/1` — there is no
  construction path through which a `RunnerJobSpec` with empty placement can
  be obtained.
  """
  @spec from_wire(map()) ::
          {:ok, t()}
          | {:error,
             :invalid_job_key | :invalid_run_ref | :invalid_runs_on | :invalid_job_message}
  def from_wire(%{} = wire) do
    new(%{
      job_key: Map.get(wire, "jobKey"),
      job_message: Map.get(wire, "jobMessage", %{}),
      run_ref: Map.get(wire, "runRef"),
      runs_on: Map.get(wire, "runsOn", [])
    })
  end

  @doc "Encodes a `RunnerJobSpec` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = spec) do
    %{
      "jobKey" => spec.job_key,
      "jobMessage" => spec.job_message,
      "runRef" => spec.run_ref,
      "runsOn" => spec.runs_on
    }
  end

  @spec validate_job_key(term()) :: :ok | {:error, :invalid_job_key}
  defp validate_job_key(job_key) when is_binary(job_key) and byte_size(job_key) > 0, do: :ok
  defp validate_job_key(_job_key), do: {:error, :invalid_job_key}

  @spec validate_run_ref(term()) :: :ok | {:error, :invalid_run_ref}
  defp validate_run_ref(run_ref) when is_binary(run_ref) and byte_size(run_ref) > 0, do: :ok
  defp validate_run_ref(_run_ref), do: {:error, :invalid_run_ref}

  @doc false
  # runs_on must be a non-empty list of binaries: nil, missing, [] or a list
  # containing anything but strings are all rejected. There is exactly one
  # gate for this rule, exercised by every public construction path.
  @spec validate_runs_on(term()) :: :ok | {:error, :invalid_runs_on}
  defp validate_runs_on(runs_on) when is_list(runs_on) and runs_on != [] do
    if Enum.all?(runs_on, &is_binary/1) do
      :ok
    else
      {:error, :invalid_runs_on}
    end
  end

  defp validate_runs_on(_runs_on), do: {:error, :invalid_runs_on}

  @spec validate_job_message(term()) :: :ok | {:error, :invalid_job_message}
  defp validate_job_message(job_message) when is_map(job_message), do: :ok
  defp validate_job_message(_job_message), do: {:error, :invalid_job_message}
end

defimpl Jason.Encoder, for: CrestCiContract.RunnerJobSpec do
  def encode(spec, opts) do
    spec
    |> CrestCiContract.RunnerJobSpec.to_wire()
    |> Jason.Encode.map(opts)
  end
end
