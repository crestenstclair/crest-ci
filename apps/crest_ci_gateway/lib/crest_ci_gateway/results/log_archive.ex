defmodule CrestCiGateway.LogArchive do
  @moduledoc """
  `LogArchive` — metadata of a compacted per-job log.

  A plain value object: no process state, no I/O. Once a job's per-step
  `CrestCiGateway.LogChunk`s are compacted into a single durable log blob
  (keyed by run + job, via `CrestCiContract.DeterministicNaming`), this is
  the metadata record that describes the compacted result — how large it
  is, how many lines it holds, and a stable reference to the underlying
  storage location.

  Fields:
    * `job_key` — the `CrestCiContract.JobKey` the archive belongs to
    * `run_ref` — a stable reference to the underlying blob storage
      location for the compacted log (e.g. the deterministic name/path
      the archive was written under); opaque to this module
    * `byte_size` — total size in bytes of the compacted log content
    * `line_count` — total number of lines in the compacted log content

  This module holds no reference to the log bytes themselves — it is
  metadata only. `digest/1` is provided as a pure helper for callers that
  *do* hold the compacted content and want a stable integrity fingerprint
  to store alongside this metadata (e.g. to detect silent blob corruption
  across replicas); it uses `:crypto` (sha256) and introduces no new
  dependency.

  Like every value object in this system, construction never raises:
  malformed input yields `{:error, :invalid_log_archive}` rather than a
  crash, and equal field values always produce equal (comparable)
  structs — there is no hidden identity beyond the fields themselves.
  """

  alias CrestCiContract.JobKey

  @enforce_keys [:job_key, :run_ref, :byte_size, :line_count]
  defstruct [:job_key, :run_ref, :byte_size, :line_count]

  @type t :: %__MODULE__{
          job_key: JobKey.t(),
          run_ref: String.t(),
          byte_size: non_neg_integer(),
          line_count: non_neg_integer()
        }

  @doc """
  Builds a `LogArchive` from field values, validating basic shape:
  `job_key` must be a valid `JobKey`, `run_ref` a non-empty binary,
  `byte_size` a non-negative integer, and `line_count` a non-negative
  integer. Returns `{:error, :invalid_log_archive}` for anything else
  rather than raising.

  Zero is an accepted `byte_size`/`line_count` — an archive of an empty
  compacted log (a job that produced no output) is valid, if unusual.
  """
  @spec new(JobKey.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_log_archive}
  def new(job_key, run_ref, byte_size, line_count)
      when is_binary(run_ref) and byte_size(run_ref) > 0 and
             is_integer(byte_size) and byte_size >= 0 and
             is_integer(line_count) and line_count >= 0 do
    case JobKey.new(job_key) do
      {:ok, valid_job_key} ->
        {:ok,
         %__MODULE__{
           job_key: valid_job_key,
           run_ref: run_ref,
           byte_size: byte_size,
           line_count: line_count
         }}

      {:error, :invalid_job_key} ->
        {:error, :invalid_log_archive}
    end
  end

  def new(_job_key, _run_ref, _byte_size, _line_count), do: {:error, :invalid_log_archive}

  @doc """
  Computes a stable sha256 integrity digest of compacted log content,
  hex-encoded (lowercase). Pure and deterministic: identical content
  always yields an identical digest, regardless of which gateway replica
  or how many times it is computed.

  This is a standalone helper — `LogArchive` itself does not store a
  digest field (the declared state is `byteSize`/`jobKey`/`lineCount`/
  `runRef` only), but callers that persist archive metadata alongside the
  blob may want this to detect corruption.
  """
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Renders a `LogArchive` to the Kubernetes/HTTP JSON wire map (camelCase
  keys), suitable for `Jason.encode!/1`.
  """
  @spec to_wire(t()) :: %{String.t() => String.t() | non_neg_integer()}
  def to_wire(%__MODULE__{} = archive) do
    %{
      "jobKey" => archive.job_key,
      "runRef" => archive.run_ref,
      "byteSize" => archive.byte_size,
      "lineCount" => archive.line_count
    }
  end

  @doc """
  Parses a JSON wire map (string-keyed, camelCase, as produced by
  `Jason.decode!/1`) into a `LogArchive`. Rejects maps missing any
  required field, or with a field of the wrong type, returning
  `{:error, :invalid_log_archive}` rather than raising.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_log_archive}
  def from_wire(%{} = wire) do
    with {:ok, job_key} <- fetch_string(wire, "jobKey"),
         {:ok, run_ref} <- fetch_string(wire, "runRef"),
         {:ok, byte_size} <- fetch_non_neg_integer(wire, "byteSize"),
         {:ok, line_count} <- fetch_non_neg_integer(wire, "lineCount") do
      new(job_key, run_ref, byte_size, line_count)
    else
      :error -> {:error, :invalid_log_archive}
    end
  end

  def from_wire(_other), do: {:error, :invalid_log_archive}

  @wire_keys ~w(jobKey runRef byteSize lineCount)

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
