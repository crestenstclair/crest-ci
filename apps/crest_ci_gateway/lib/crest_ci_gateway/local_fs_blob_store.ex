defmodule CrestCiGateway.LocalFsBlobStore do
  @moduledoc """
  Filesystem adapter implementing `port.Gateway.BlobStore` over chunk files
  keyed by `(run, job, step, seq)`.

  Layout: `<root>/<run>/<job>/<step>/<seq>.chunk` — one file per chunk.
  Idempotency is structural: the chunk's path is fully derived from its key,
  and `append_chunk/6` opens the file with `:exclusive` so a second write to
  an existing key is a guaranteed no-op rather than a duplicate append. No
  in-process state is held — every read/write goes straight to disk, so this
  adapter is safely shared across replicas that see the same filesystem and
  safely reconstructed after a crash (nothing lives in memory that isn't
  re-derivable from the files themselves).

  `delete_job/3` removes a job's entire chunk directory — used by
  `applicationService.Results.ArchiveOnComplete` once a job's chunks have
  been durably compacted into a `CrestCiGateway.LogArchive`, so a job's
  live chunks never linger once an archive vouches for their content.
  Removing an already-absent (or already-deleted) job directory is a
  no-op success, matching this port's idempotent-everywhere contract.
  """

  @behaviour CrestCiGateway.BlobStore

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @default_root "var/blobs"

  @doc """
  Build a store rooted at `root` (defaults to `"var/blobs"`). Pass an
  explicit root in tests to isolate each test's filesystem footprint.
  """
  @spec new(String.t()) :: t()
  def new(root \\ @default_root) when is_binary(root) do
    %__MODULE__{root: root}
  end

  @impl CrestCiGateway.BlobStore
  @spec append_chunk(t(), String.t(), String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def append_chunk(%__MODULE__{root: root}, run, job, step, seq, content)
      when is_integer(seq) and seq >= 0 do
    path = chunk_path(root, run, job, step, seq)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      write_if_absent(path, content)
    end
  end

  @impl CrestCiGateway.BlobStore
  @spec read_log(t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_log(%__MODULE__{root: root}, run, job) do
    job_dir = Path.join([root, run, job])

    case File.ls(job_dir) do
      {:ok, steps} ->
        {:ok, read_ordered(job_dir, steps)}

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl CrestCiGateway.BlobStore
  @spec list_chunks(t(), String.t(), String.t()) ::
          {:ok, [{String.t(), non_neg_integer(), binary()}]} | {:error, term()}
  def list_chunks(%__MODULE__{root: root}, run, job) do
    job_dir = Path.join([root, run, job])

    case File.ls(job_dir) do
      {:ok, steps} ->
        {:ok, list_ordered(job_dir, steps)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl CrestCiGateway.BlobStore
  @spec delete_job(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_job(%__MODULE__{root: root}, run, job) do
    job_dir = Path.join([root, run, job])

    case File.rm_rf(job_dir) do
      {:ok, _paths} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # -- internal --------------------------------------------------------

  defp write_if_absent(path, content) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, content)
          :ok
        after
          File.close(io)
        end

      {:error, :eexist} ->
        # Chunk already stored under this exact (run, job, step, seq) key —
        # idempotent no-op, not an error.
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_ordered(job_dir, steps) do
    steps
    |> Enum.sort()
    |> Enum.flat_map(fn step -> read_step_chunks(job_dir, step) end)
    |> IO.iodata_to_binary()
  end

  defp read_step_chunks(job_dir, step) do
    step_dir = Path.join(job_dir, step)

    case File.ls(step_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&parse_seq/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.map(fn seq ->
          case File.read(Path.join(step_dir, "#{seq}.chunk")) do
            {:ok, data} -> data
            {:error, _reason} -> ""
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp list_ordered(job_dir, steps) do
    steps
    |> Enum.sort()
    |> Enum.flat_map(fn step -> list_step_chunks(job_dir, step) end)
  end

  defp list_step_chunks(job_dir, step) do
    step_dir = Path.join(job_dir, step)

    case File.ls(step_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&parse_seq/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.map(fn seq ->
          case File.read(Path.join(step_dir, "#{seq}.chunk")) do
            {:ok, data} -> {step, seq, data}
            {:error, _reason} -> {step, seq, ""}
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  @seq_pattern ~r/^(\d+)\.chunk$/

  defp parse_seq(filename) do
    case Regex.run(@seq_pattern, filename) do
      [_, seq_str] -> String.to_integer(seq_str)
      _ -> nil
    end
  end

  defp chunk_path(root, run, job, step, seq) do
    Path.join([root, run, job, step, "#{seq}.chunk"])
  end
end
