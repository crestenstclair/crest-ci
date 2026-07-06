defmodule CrestCiContract.OwnerReference do
  @moduledoc """
  A parent pointer used for cascade semantics: every child resource this
  system creates (RunnerJob, Pod, etc.) carries an `OwnerReference` back to
  the parent that spawned it, mirroring the Kubernetes owner-reference
  convention so garbage collection and cascade-delete work the same way the
  platform already expects.

  It is a plain, immutable value object — four required string fields with
  no independent identity or lifecycle of its own. `ObjectMeta.owner_references`
  holds a list of these.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1`, and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls, so `encode then decode` always reproduces the
  original struct.
  """

  @type t :: %__MODULE__{
          api_version: String.t(),
          kind: String.t(),
          name: String.t(),
          uid: String.t()
        }

  @enforce_keys [:api_version, :kind, :name, :uid]
  defstruct [:api_version, :kind, :name, :uid]

  @doc """
  Builds a new `OwnerReference` from field values (atom keys). All four
  fields are required non-empty binaries — an `OwnerReference` missing any
  of `apiVersion`/`kind`/`name`/`uid` cannot identify a parent, so
  construction is rejected rather than defaulted.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_owner_reference}
  def new(fields) when is_map(fields) do
    with {:ok, api_version} <- fetch_binary(fields, :api_version),
         {:ok, kind} <- fetch_binary(fields, :kind),
         {:ok, name} <- fetch_binary(fields, :name),
         {:ok, uid} <- fetch_binary(fields, :uid) do
      {:ok, %__MODULE__{api_version: api_version, kind: kind, name: name, uid: uid}}
    end
  end

  def new(_fields), do: {:error, :invalid_owner_reference}

  @doc """
  Decodes an `OwnerReference` from its Kubernetes JSON wire shape: a map
  with camelCase string keys `"apiVersion"`, `"kind"`, `"name"`, `"uid"`.
  Returns `{:error, :invalid_owner_reference}` for any missing or
  non-binary field.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_owner_reference}
  def from_wire(%{} = wire) do
    new(%{
      api_version: Map.get(wire, "apiVersion"),
      kind: Map.get(wire, "kind"),
      name: Map.get(wire, "name"),
      uid: Map.get(wire, "uid")
    })
  end

  def from_wire(_wire), do: {:error, :invalid_owner_reference}

  @doc "Encodes an `OwnerReference` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = ref) do
    %{
      "apiVersion" => ref.api_version,
      "kind" => ref.kind,
      "name" => ref.name,
      "uid" => ref.uid
    }
  end

  @spec fetch_binary(map(), atom()) :: {:ok, String.t()} | {:error, :invalid_owner_reference}
  defp fetch_binary(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :invalid_owner_reference}
    end
  end
end

defimpl Jason.Encoder, for: CrestCiContract.OwnerReference do
  def encode(ref, opts) do
    ref
    |> CrestCiContract.OwnerReference.to_wire()
    |> Jason.Encode.map(opts)
  end
end
