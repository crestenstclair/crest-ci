defmodule CrestCiGateway.Results.LocalFsArtifactStore do
  @moduledoc """
  Filesystem adapter implementing `port.Results.ArtifactStore` over a
  staging-then-atomic-rename layout.

  Layout:

    * `<root>/staging/<upload_ref>/<part_index>` — one file per uploaded
      part, plus a `_meta` sidecar (written once, at `create/5`) carrying
      `run`, `job`, `name`, and `declared_size` so `finalize/3` — which is
      handed only `upload_ref` and `declared_digest` — can recover the
      rest of the identity key.
    * `<root>/artifacts/<run>/<name>` — the finalized artifact's raw
      bytes, made visible by `File.rename/2` from a same-directory temp
      file. Rename on a POSIX filesystem is atomic, so a reader can never
      observe a partially-written file: the path either doesn't exist yet
      or already holds the complete, verified content.
    * `<root>/artifacts/<run>/.records/<safe_key(name)>.json` — the
      finalized `ArtifactRecord`'s wire-format metadata (digest,
      finalized_at, job_key, size_bytes), written via the same
      temp-then-rename pattern, and what `list/2` enumerates. A name's
      `safe_key/1` flattens any path separators, mirroring the existing
      convention for storage-safe key fragments.

  `upload_ref` is deterministic: it's derived from `(run, job, name)`, so
  a `create/5` retried after a crash (this adapter holds no in-process
  state — everything needed to resume or discover an upload lives on
  disk) reliably lands on the same staging directory. Creating that
  directory uses `File.mkdir/1` (non-recursive, non-`_p`), which fails
  with `:eexist` if the directory is already there — that failure is
  surfaced as `{:error, :already_exists}`, this adapter's local mirror of
  the "409 AlreadyExists on create is a no-op, not an error" convention
  used for child-resource creation elsewhere in this project.

  `upload_part/4` is idempotent by `(upload_ref, part_index)`: each part
  is written with `File.open(path, [:write, :exclusive])`, so a resent
  part with the same index is a guaranteed no-op — the first write wins,
  never a duplicate or corrupted append.

  `finalize/3` is the atomic commit point. It reassembles all staged
  parts in ascending index order, verifies the assembled size and sha256
  digest against `declared_digest`, and only on success renames the
  content and record-metadata files into place before removing the
  staging directory. A size or digest mismatch writes nothing to the
  `artifacts/` tree — `list/2` and `read/3` are unaffected, exactly as
  the port contract requires.
  """

  @behaviour CrestCiGateway.Results.ArtifactStore

  alias CrestCiContract.JobKey
  alias CrestCiGateway.Results.ArtifactName
  alias CrestCiGateway.Results.ArtifactRecord

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @default_root "var/artifacts"
  @records_dirname ".records"
  @meta_filename "_meta"
  @part_pattern ~r/^(\d+)$/

  @doc """
  Build a store rooted at `root` (defaults to `"var/artifacts"`). Pass an
  explicit root in tests to isolate each test's filesystem footprint.
  """
  @spec new(String.t()) :: t()
  def new(root \\ @default_root) when is_binary(root) do
    %__MODULE__{root: root}
  end

  @impl CrestCiGateway.Results.ArtifactStore
  @spec create(t(), String.t(), JobKey.t(), ArtifactName.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, :already_exists | term()}
  def create(%__MODULE__{root: root}, run, job, name, declared_size)
      when is_binary(run) and is_integer(declared_size) and declared_size >= 0 do
    if File.regular?(artifact_path(root, run, name)) do
      {:error, :already_exists}
    else
      upload_ref = upload_ref_for(run, job, name)
      staging_dir = staging_dir(root, upload_ref)

      with :ok <- File.mkdir_p(Path.join(root, "staging")),
           :ok <- mkdir_exclusive(staging_dir),
           :ok <- write_meta(meta_path(staging_dir), run, job, name, declared_size) do
        {:ok, upload_ref}
      end
    end
  end

  @impl CrestCiGateway.Results.ArtifactStore
  @spec upload_part(t(), term(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  def upload_part(%__MODULE__{root: root}, upload_ref, part_index, content)
      when is_integer(part_index) and part_index >= 0 and is_binary(content) do
    staging_dir = staging_dir(root, upload_ref)

    if File.regular?(meta_path(staging_dir)) do
      part_path = Path.join(staging_dir, Integer.to_string(part_index))
      write_if_absent(part_path, content)
    else
      {:error, :upload_not_found}
    end
  end

  @impl CrestCiGateway.Results.ArtifactStore
  @spec finalize(t(), term(), String.t()) ::
          {:ok, ArtifactRecord.t()} | {:error, :digest_mismatch | :size_mismatch | term()}
  def finalize(%__MODULE__{root: root}, upload_ref, declared_digest) do
    staging_dir = staging_dir(root, upload_ref)

    with {:ok, meta} <- read_meta(meta_path(staging_dir)) do
      assembled = assemble_parts(staging_dir)

      with :ok <- check_size(assembled, meta.declared_size),
           :ok <- check_digest(assembled, declared_digest) do
        commit(root, meta, staging_dir, assembled, declared_digest)
      end
    end
  end

  @impl CrestCiGateway.Results.ArtifactStore
  @spec list(t(), String.t()) :: {:ok, [ArtifactRecord.t()]}
  def list(%__MODULE__{root: root}, run) do
    records_dir = records_dir(root, run)

    case File.ls(records_dir) do
      {:ok, filenames} ->
        records =
          filenames
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn filename -> load_record(Path.join(records_dir, filename)) end)
          |> Enum.reject(&is_nil/1)

        {:ok, records}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  @impl CrestCiGateway.Results.ArtifactStore
  @spec read(t(), String.t(), ArtifactName.t()) :: {:ok, binary()} | {:error, :not_found}
  def read(%__MODULE__{root: root}, run, name) do
    case File.read(artifact_path(root, run, name)) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # -- internal --------------------------------------------------------

  defp commit(root, meta, staging_dir, assembled, digest) do
    final_path = artifact_path(root, meta.run, meta.name)
    record_path = record_meta_path(root, meta.run, meta.name)

    with {:ok, record} <-
           ArtifactRecord.new(
             digest,
             DateTime.to_iso8601(DateTime.utc_now()),
             meta.job,
             meta.name,
             meta.run,
             byte_size(assembled)
           ),
         :ok <- File.mkdir_p(Path.dirname(final_path)),
         :ok <- File.mkdir_p(Path.dirname(record_path)),
         :ok <- atomic_write(final_path, assembled),
         :ok <- atomic_write(record_path, Jason.encode!(ArtifactRecord.to_wire(record))) do
      File.rm_rf(staging_dir)
      {:ok, record}
    end
  end

  defp mkdir_exclusive(dir) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

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
        # Already stored under this exact (upload_ref, part_index) key —
        # idempotent no-op, not an error.
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_write(path, content) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp assemble_parts(staging_dir) do
    case File.ls(staging_dir) do
      {:ok, filenames} ->
        filenames
        |> Enum.map(&parse_part_index/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.map(fn index ->
          case File.read(Path.join(staging_dir, Integer.to_string(index))) do
            {:ok, data} -> data
            {:error, _reason} -> ""
          end
        end)
        |> IO.iodata_to_binary()

      {:error, _reason} ->
        ""
    end
  end

  defp parse_part_index(filename) do
    case Regex.run(@part_pattern, filename) do
      [_, digits] -> String.to_integer(digits)
      _other -> nil
    end
  end

  defp check_size(assembled, declared_size) do
    if byte_size(assembled) == declared_size do
      :ok
    else
      {:error, :size_mismatch}
    end
  end

  defp check_digest(assembled, declared_digest) do
    if ArtifactRecord.digest(assembled) == declared_digest do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp write_meta(meta_path, run, job, name, declared_size) do
    data =
      :erlang.term_to_binary(%{run: run, job: job, name: name, declared_size: declared_size})

    File.write(meta_path, data)
  end

  defp read_meta(meta_path) do
    case File.read(meta_path) do
      {:ok, data} ->
        {:ok, :erlang.binary_to_term(data, [:safe])}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp load_record(path) do
    with {:ok, json} <- File.read(path),
         {:ok, wire} <- Jason.decode(json),
         {:ok, record} <- ArtifactRecord.from_wire(wire) do
      record
    else
      _other -> nil
    end
  end

  defp upload_ref_for(run, job, name) do
    key = Enum.join([run, JobKey.slug(job), ArtifactName.safe_key(name)], " ")

    :crypto.hash(:sha256, key)
    |> Base.encode16(case: :lower)
  end

  defp staging_dir(root, upload_ref), do: Path.join([root, "staging", upload_ref])
  defp meta_path(staging_dir), do: Path.join(staging_dir, @meta_filename)
  defp artifact_path(root, run, name), do: Path.join([root, "artifacts", run, name])
  defp records_dir(root, run), do: Path.join([root, "artifacts", run, @records_dirname])

  defp record_meta_path(root, run, name) do
    Path.join(records_dir(root, run), "#{ArtifactName.safe_key(name)}.json")
  end
end
