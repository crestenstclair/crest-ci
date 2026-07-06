defmodule CrestCiContract.JobKey do
  @moduledoc """
  A `JobKey` identifies a job's path within a plan, e.g. `"build"` or
  `"test/m-3f9a2c"` (matrix jobs are suffixed with `/m-<matrix hash>`).

  It is a plain string value object — no wrapping struct, since both
  Kubernetes object names and the JSON wire shape want a bare string.

  `slug/1` derives the Kubernetes-resource-name-safe fragment used by
  `CrestCiContract.DeterministicNaming` and `CrestCiContract.LabelSchema`:
  lowercased, `/` replaced by `-`, and restricted to the charset
  `[a-z0-9-]`.
  """

  @type t :: String.t()

  @doc """
  Validate that a value is usable as a `JobKey` — a non-empty binary.

  Kept intentionally permissive: the *raw* JobKey may contain characters
  that are meaningful in a plan path (like `/`) but are not yet
  Kubernetes-name-safe. Use `slug/1` to derive the safe form.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_job_key}
  def new(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  def new(_value), do: {:error, :invalid_job_key}

  @doc """
  Slug a `JobKey` into a Kubernetes-name-safe fragment: lowercased, with
  every `/` replaced by `-`, and any character outside `[a-z0-9-]`
  replaced by `-`.

  Pure and deterministic — identical input always yields identical output.
  """
  @spec slug(t()) :: String.t()
  def slug(job_key) when is_binary(job_key) do
    job_key
    |> String.downcase()
    |> String.replace("/", "-")
    |> String.replace(~r/[^a-z0-9-]/, "-")
  end
end
