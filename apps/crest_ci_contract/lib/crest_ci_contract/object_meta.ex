defmodule CrestCiContract.ObjectMeta do
  @moduledoc """
  `ObjectMeta` is the metadata envelope every stored object carries,
  mirroring Kubernetes `ObjectMeta` in camelCase JSON: `name`, `namespace`,
  `uid`, `resourceVersion`, `labels`, `annotations`, `ownerReferences`, and
  `creationTimestamp`.

  Nothing in this project reconciles or arbitrates based on `ObjectMeta`
  directly — the controller and gateway read/write it as part of a larger
  object envelope (metadata/spec/status) fetched or persisted through
  `port.Contract.KubeClient`. This module's only job is the shape of that
  envelope and its round trip to/from the Kubernetes JSON wire format.

  `ownerReferences` is a list of `CrestCiContract.OwnerReference` values —
  `ObjectMeta` composes that value object rather than re-declaring its shape
  privately, so there is exactly one definition of the owner-reference wire
  format (`apiVersion`, `kind`, `name`, `uid`) and both value objects'
  `to_wire`/`from_wire` pairs stay in lockstep.

  Serializes to/from the wire shape via `to_wire/1` / `from_wire/1`, and via
  `Jason.Encoder` for direct `Jason.encode!/1` calls.
  """

  alias CrestCiContract.OwnerReference

  @type t :: %__MODULE__{
          annotations: %{optional(String.t()) => String.t()},
          creation_timestamp: String.t(),
          labels: %{optional(String.t()) => String.t()},
          name: String.t(),
          namespace: String.t(),
          owner_references: [OwnerReference.t()],
          resource_version: String.t(),
          uid: String.t()
        }

  defstruct annotations: %{},
            creation_timestamp: "",
            labels: %{},
            name: "",
            namespace: "",
            owner_references: [],
            resource_version: "",
            uid: ""

  @doc """
  Builds a new `ObjectMeta` from field values (atom keys). Every field is
  optional and defaults to its zero value (`""` for strings, `%{}` for
  maps, `[]` for `owner_references`), so partially-known metadata (e.g. a
  freshly-constructed object with no `resourceVersion` yet) is always
  representable. `owner_references`, when given, is expected to be a list
  of `CrestCiContract.OwnerReference` structs.
  """
  @spec new(map()) :: {:ok, t()}
  def new(fields) when is_map(fields) do
    {:ok,
     %__MODULE__{
       annotations: Map.get(fields, :annotations, %{}),
       creation_timestamp: Map.get(fields, :creation_timestamp, ""),
       labels: Map.get(fields, :labels, %{}),
       name: Map.get(fields, :name, ""),
       namespace: Map.get(fields, :namespace, ""),
       owner_references: Map.get(fields, :owner_references, []),
       resource_version: Map.get(fields, :resource_version, ""),
       uid: Map.get(fields, :uid, "")
     }}
  end

  @doc """
  Decodes an `ObjectMeta` from its Kubernetes JSON wire shape: a map with
  camelCase string keys. Missing keys default the same way `new/1` does.
  Each entry of `ownerReferences` is decoded via
  `CrestCiContract.OwnerReference.from_wire/1`; an invalid owner reference
  fails the whole decode. Returns `{:error, :invalid_object_meta}` for
  non-map input or an invalid owner reference.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_object_meta}
  def from_wire(%{} = wire) do
    with {:ok, owner_references} <-
           wire
           |> Map.get("ownerReferences", [])
           |> List.wrap()
           |> decode_owner_references() do
      new(%{
        annotations: Map.get(wire, "annotations", %{}),
        creation_timestamp: Map.get(wire, "creationTimestamp", ""),
        labels: Map.get(wire, "labels", %{}),
        name: Map.get(wire, "name", ""),
        namespace: Map.get(wire, "namespace", ""),
        owner_references: owner_references,
        resource_version: Map.get(wire, "resourceVersion", ""),
        uid: Map.get(wire, "uid", "")
      })
    end
  end

  def from_wire(_other), do: {:error, :invalid_object_meta}

  @doc """
  Encodes an `ObjectMeta` into its Kubernetes JSON wire shape (camelCase
  keys). Each entry of `owner_references` is encoded via
  `CrestCiContract.OwnerReference.to_wire/1`.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = meta) do
    %{
      "annotations" => meta.annotations,
      "creationTimestamp" => meta.creation_timestamp,
      "labels" => meta.labels,
      "name" => meta.name,
      "namespace" => meta.namespace,
      "ownerReferences" => Enum.map(meta.owner_references, &OwnerReference.to_wire/1),
      "resourceVersion" => meta.resource_version,
      "uid" => meta.uid
    }
  end

  @spec decode_owner_references([map()]) ::
          {:ok, [OwnerReference.t()]} | {:error, :invalid_object_meta}
  defp decode_owner_references(wire_refs) do
    wire_refs
    |> Enum.reduce_while({:ok, []}, fn wire_ref, {:ok, acc} ->
      case OwnerReference.from_wire(wire_ref) do
        {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
        {:error, _} -> {:halt, {:error, :invalid_object_meta}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _} = error -> error
    end
  end
end

defimpl Jason.Encoder, for: CrestCiContract.ObjectMeta do
  def encode(meta, opts) do
    meta
    |> CrestCiContract.ObjectMeta.to_wire()
    |> Jason.Encode.map(opts)
  end
end
