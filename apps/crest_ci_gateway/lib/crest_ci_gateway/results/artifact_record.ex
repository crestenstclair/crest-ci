defmodule CrestCiGateway.Results.ArtifactRecord do
  @moduledoc """
  `ArtifactRecord` — a finalized artifact's metadata.

  A plain value object: no process state, no I/O. It is the shape produced
  once a runner's artifact upload for a job is complete, and the shape
  served back over the gateway's HTTP surface when a caller looks up an
  artifact by `(run_ref, job_key, name)`.

  Fields:
    * `digest` — hex-encoded SHA-256 of the artifact's full content,
      computed via `digest/1` (uses `:crypto`, no new external deps)
    * `finalized_at` — ISO 8601 timestamp of when the artifact was
      finalized (content fully received and digested)
    * `job_key` — the `CrestCiContract.JobKey` the artifact belongs to
    * `name` — the `CrestCiGateway.Results.ArtifactName` within the job
    * `run_ref` — the run this artifact belongs to (run ULID)
    * `size_bytes` — the artifact's total size in bytes

  Identity key: `(run_ref, job_key, name)`. Re-finalizing an artifact under
  the same key is a metadata overwrite, never a duplicate — this module
  itself is just data and does not enforce that; it only refuses to
  construct a record with a malformed shape. Authoritative storage lives
  in the resource store, not in this struct or any gateway process memory
  (see the "every component can be killed at any moment" architectural
  invariant) — this module is the wire/domain shape callers pass around,
  not the source of truth itself.
  """

  alias CrestCiContract.JobKey
  alias CrestCiGateway.Results.ArtifactName

  @enforce_keys [:digest, :finalized_at, :job_key, :name, :run_ref, :size_bytes]
  defstruct [:digest, :finalized_at, :job_key, :name, :run_ref, :size_bytes]

  @type t :: %__MODULE__{
          digest: String.t(),
          finalized_at: String.t(),
          job_key: JobKey.t(),
          name: ArtifactName.t(),
          run_ref: String.t(),
          size_bytes: non_neg_integer()
        }

  @digest_pattern ~r/^[0-9a-f]{64}$/

  @doc """
  Builds an `ArtifactRecord` from field values, validating basic shape:
  `digest` must be a 64-character lowercase-hex SHA-256, `finalized_at`
  a parseable ISO 8601 timestamp, `job_key` a valid `JobKey`, `name` a
  valid `ArtifactName`, `run_ref` a non-empty binary, and `size_bytes` a
  non-negative integer. Returns `{:error, :invalid_artifact_record}` for
  anything else rather than raising.
  """
  @spec new(String.t(), String.t(), JobKey.t(), ArtifactName.t(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_artifact_record}
  def new(digest, finalized_at, job_key, name, run_ref, size_bytes)
      when is_binary(run_ref) and byte_size(run_ref) > 0 and
             is_integer(size_bytes) and size_bytes >= 0 do
    with {:ok, valid_digest} <- validate_digest(digest),
         {:ok, valid_finalized_at} <- validate_timestamp(finalized_at),
         {:ok, valid_job_key} <- job_key_or_error(job_key),
         {:ok, valid_name} <- name_or_error(name) do
      {:ok,
       %__MODULE__{
         digest: valid_digest,
         finalized_at: valid_finalized_at,
         job_key: valid_job_key,
         name: valid_name,
         run_ref: run_ref,
         size_bytes: size_bytes
       }}
    else
      :error -> {:error, :invalid_artifact_record}
    end
  end

  def new(_digest, _finalized_at, _job_key, _name, _run_ref, _size_bytes),
    do: {:error, :invalid_artifact_record}

  @doc """
  The `(run_ref, job_key, name)` identity key this record is looked up
  and overwritten by. Two records with equal keys describe the same
  logical artifact, no matter how many times or via which gateway
  replica finalization was observed.
  """
  @spec key(t()) :: {String.t(), JobKey.t(), ArtifactName.t()}
  def key(%__MODULE__{run_ref: run_ref, job_key: job_key, name: name}),
    do: {run_ref, job_key, name}

  @doc """
  Computes the hex-encoded SHA-256 digest of artifact content. Pure and
  deterministic — identical content always yields identical digest. Uses
  `:crypto`, per the "no new external deps" implementation note.
  """
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Renders an `ArtifactRecord` to the Kubernetes/HTTP JSON wire map
  (camelCase keys), suitable for `Jason.encode!/1`.
  """
  @spec to_wire(t()) :: %{String.t() => String.t() | non_neg_integer()}
  def to_wire(%__MODULE__{} = record) do
    %{
      "digest" => record.digest,
      "finalizedAt" => record.finalized_at,
      "jobKey" => record.job_key,
      "name" => record.name,
      "runRef" => record.run_ref,
      "sizeBytes" => record.size_bytes
    }
  end

  @doc """
  Parses a JSON wire map (string-keyed, camelCase, as produced by
  `Jason.decode!/1`) into an `ArtifactRecord`. Rejects maps missing any
  required field, or with a field of the wrong type, returning
  `{:error, :invalid_artifact_record}` rather than raising — out-of-shape
  wire data is never silently coerced.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_artifact_record}
  def from_wire(%{} = wire) do
    with {:ok, digest} <- fetch_string(wire, "digest"),
         {:ok, finalized_at} <- fetch_string(wire, "finalizedAt"),
         {:ok, job_key} <- fetch_string(wire, "jobKey"),
         {:ok, name} <- fetch_string(wire, "name"),
         {:ok, run_ref} <- fetch_string(wire, "runRef"),
         {:ok, size_bytes} <- fetch_non_neg_integer(wire, "sizeBytes") do
      new(digest, finalized_at, job_key, name, run_ref, size_bytes)
    else
      :error -> {:error, :invalid_artifact_record}
    end
  end

  def from_wire(_other), do: {:error, :invalid_artifact_record}

  # -- internal ------------------------------------------------------------

  @wire_keys ~w(digest finalizedAt jobKey name runRef sizeBytes)

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

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(@digest_pattern, value) do
      {:ok, value}
    else
      :error
    end
  end

  defp validate_digest(_other), do: :error

  defp validate_timestamp(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp validate_timestamp(_other), do: :error

  defp job_key_or_error(job_key) do
    case JobKey.new(job_key) do
      {:ok, valid_job_key} -> {:ok, valid_job_key}
      {:error, :invalid_job_key} -> :error
    end
  end

  defp name_or_error(name) do
    case ArtifactName.new(name) do
      {:ok, valid_name} -> {:ok, valid_name}
      {:error, :invalid_artifact_name} -> :error
    end
  end
end
