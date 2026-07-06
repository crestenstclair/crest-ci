defmodule CrestCiGateway.Results.ArtifactName do
  @moduledoc """
  `ArtifactName` identifies a finalized artifact within a job, e.g.
  `"coverage.html"` or `"dist/app.tar.gz"`.

  It is a plain string value object — no wrapping struct, since both the
  JSON wire shape and (indirectly, via `safe_key/1`) storage paths want a
  bare string. Kept intentionally permissive on `new/1` (an artifact name
  may contain path-like segments, e.g. `"dist/app.tar.gz"`), but rejects
  path traversal so a malicious or buggy name can never escape its
  `(run, job)` storage scope.

  `safe_key/1` derives the filesystem/storage-safe fragment used to build
  a deterministic blob key alongside a run ref and job key — mirroring how
  `CrestCiContract.JobKey.slug/1` derives a Kubernetes-name-safe fragment.
  """

  @type t :: String.t()

  @doc """
  Validate that a value is usable as an `ArtifactName` — a non-empty
  binary that does not attempt path traversal (no `".."` segment, and no
  leading `/`).
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_artifact_name}
  def new(value) when is_binary(value) and byte_size(value) > 0 do
    if traversal?(value) do
      {:error, :invalid_artifact_name}
    else
      {:ok, value}
    end
  end

  def new(_value), do: {:error, :invalid_artifact_name}

  @doc """
  Derive a filesystem/storage-safe key fragment from an `ArtifactName`:
  every `/` replaced by `-`, and any character outside
  `[a-zA-Z0-9._-]` replaced by `-`.

  Pure and deterministic — identical input always yields identical output.
  """
  @spec safe_key(t()) :: String.t()
  def safe_key(name) when is_binary(name) do
    name
    |> String.replace("/", "-")
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  end

  # -- internal ----------------------------------------------------------

  defp traversal?(value) do
    String.starts_with?(value, "/") or
      value
      |> String.split("/")
      |> Enum.any?(&(&1 == ".."))
  end
end
