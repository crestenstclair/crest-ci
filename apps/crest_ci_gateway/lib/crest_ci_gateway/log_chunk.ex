defmodule CrestCiGateway.LogChunk do
  @moduledoc """
  `LogChunk` — one uploaded slice of step output.

  A plain value object: no process state, no I/O. It is the shape a runner
  POSTs to `/jobs/:name/logs` and the shape `CrestCiGateway.LogIngest` hands
  to `port.Gateway.BlobStore.append_chunk/6`.

  Fields:
    * `job_key` — the `CrestCiContract.JobKey` the chunk belongs to
    * `step` — the step name within the job this chunk's output came from
    * `seq` — the chunk's sequence number within `(job_key, step)`,
      strictly increasing per runner upload order but not required to
      arrive in order — ingestion and storage are keyed and idempotent by
      `(job, step, seq)`, never by arrival order (see the "log chunk
      ingestion is idempotent" architectural invariant)
    * `content` — the raw uploaded text slice

  Identity/idempotency key: `(job_key, step, seq)`. Re-sending a chunk with
  the same key after a reconnect must be absorbed as a no-op by
  downstream consumers (`LogIngest`, `BlobStore`) — this module itself is
  just data and does not enforce that; it only refuses to construct a
  chunk with a malformed key.
  """

  alias CrestCiContract.JobKey

  @enforce_keys [:job_key, :step, :seq, :content]
  defstruct [:job_key, :step, :seq, :content]

  @type t :: %__MODULE__{
          job_key: JobKey.t(),
          step: String.t(),
          seq: non_neg_integer(),
          content: binary()
        }

  @doc """
  Builds a `LogChunk` from field values, validating basic shape: `job_key`
  must be a valid `JobKey`, `step` a non-empty binary, `seq` a
  non-negative integer, and `content` a binary (may be empty — an empty
  chunk is a valid, if unusual, upload). Returns
  `{:error, :invalid_log_chunk}` for anything else rather than raising.
  """
  @spec new(JobKey.t(), String.t(), non_neg_integer(), binary()) ::
          {:ok, t()} | {:error, :invalid_log_chunk}
  def new(job_key, step, seq, content)
      when is_binary(step) and byte_size(step) > 0 and
             is_integer(seq) and seq >= 0 and
             is_binary(content) do
    case JobKey.new(job_key) do
      {:ok, valid_job_key} ->
        {:ok, %__MODULE__{job_key: valid_job_key, step: step, seq: seq, content: content}}

      {:error, :invalid_job_key} ->
        {:error, :invalid_log_chunk}
    end
  end

  def new(_job_key, _step, _seq, _content), do: {:error, :invalid_log_chunk}

  @doc """
  The `(job_key, step, seq)` idempotency key this chunk is ingested and
  stored under. Two chunks with equal keys are the same upload, no matter
  how many times or via which gateway replica they were sent.
  """
  @spec key(t()) :: {JobKey.t(), String.t(), non_neg_integer()}
  def key(%__MODULE__{job_key: job_key, step: step, seq: seq}), do: {job_key, step, seq}

  @doc """
  Renders a `LogChunk` to the Kubernetes/HTTP JSON wire map (camelCase
  keys), suitable for `Jason.encode!/1`.
  """
  @spec to_wire(t()) :: %{String.t() => String.t() | non_neg_integer()}
  def to_wire(%__MODULE__{} = chunk) do
    %{
      "jobKey" => chunk.job_key,
      "step" => chunk.step,
      "seq" => chunk.seq,
      "content" => chunk.content
    }
  end

  @doc """
  Parses a JSON wire map (string-keyed, camelCase, as produced by
  `Jason.decode!/1`) into a `LogChunk`. Rejects maps missing any required
  field, or with a field of the wrong type, returning
  `{:error, :invalid_log_chunk}` rather than raising — out-of-shape wire
  data (e.g. a malformed upload body) is never silently coerced.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_log_chunk}
  def from_wire(%{} = wire) do
    with {:ok, job_key} <- fetch_string(wire, "jobKey"),
         {:ok, step} <- fetch_string(wire, "step"),
         {:ok, seq} <- fetch_non_neg_integer(wire, "seq"),
         {:ok, content} <- fetch_string(wire, "content") do
      new(job_key, step, seq, content)
    else
      :error -> {:error, :invalid_log_chunk}
    end
  end

  def from_wire(_other), do: {:error, :invalid_log_chunk}

  @wire_keys ~w(jobKey step seq content)

  defp fetch_string(wire, key) when key in @wire_keys do
    case Map.get(wire, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_non_neg_integer(wire, key) when key in @wire_keys do
    case Map.get(wire, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> :error
    end
  end
end
