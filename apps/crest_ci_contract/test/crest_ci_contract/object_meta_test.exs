defmodule CrestCiContract.ObjectMetaTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.ObjectMeta
  alias CrestCiContract.OwnerReference

  describe "new/1" do
    test "defaults every field when given an empty map" do
      assert {:ok, meta} = ObjectMeta.new(%{})

      assert meta.annotations == %{}
      assert meta.creation_timestamp == ""
      assert meta.labels == %{}
      assert meta.name == ""
      assert meta.namespace == ""
      assert meta.owner_references == []
      assert meta.resource_version == ""
      assert meta.uid == ""
    end

    test "accepts fully-populated fields" do
      {:ok, owner_ref} =
        OwnerReference.new(%{api_version: "v1", kind: "WorkflowRun", name: "r", uid: "u"})

      assert {:ok, meta} =
               ObjectMeta.new(%{
                 annotations: %{"a" => "1"},
                 creation_timestamp: "2026-07-05T00:00:00Z",
                 labels: %{"l" => "2"},
                 name: "run-01jz",
                 namespace: "crest-ci",
                 owner_references: [owner_ref],
                 resource_version: "123",
                 uid: "abc"
               })

      assert meta.name == "run-01jz"
      assert meta.namespace == "crest-ci"
      assert meta.resource_version == "123"

      assert [%OwnerReference{api_version: "v1", kind: "WorkflowRun", name: "r", uid: "u"}] =
               meta.owner_references
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces camelCase keys" do
      {:ok, owner_ref} =
        OwnerReference.new(%{api_version: "v1", kind: "WorkflowRun", name: "parent", uid: "u-1"})

      {:ok, meta} =
        ObjectMeta.new(%{
          creation_timestamp: "2026-07-05T00:00:00Z",
          name: "run-01jz",
          namespace: "crest-ci",
          resource_version: "123",
          uid: "abc",
          owner_references: [owner_ref]
        })

      wire = ObjectMeta.to_wire(meta)

      assert wire == %{
               "annotations" => %{},
               "creationTimestamp" => "2026-07-05T00:00:00Z",
               "labels" => %{},
               "name" => "run-01jz",
               "namespace" => "crest-ci",
               "ownerReferences" => [
                 %{
                   "apiVersion" => "v1",
                   "kind" => "WorkflowRun",
                   "name" => "parent",
                   "uid" => "u-1"
                 }
               ],
               "resourceVersion" => "123",
               "uid" => "abc"
             }
    end

    test "from_wire parses a Kubernetes-shaped map" do
      wire = %{
        "annotations" => %{"a" => "1"},
        "creationTimestamp" => "2026-07-05T00:00:00Z",
        "labels" => %{"l" => "2"},
        "name" => "run-01jz",
        "namespace" => "crest-ci",
        "ownerReferences" => [
          %{"apiVersion" => "v1", "kind" => "WorkflowRun", "name" => "parent", "uid" => "u-1"}
        ],
        "resourceVersion" => "123",
        "uid" => "abc"
      }

      assert {:ok, meta} = ObjectMeta.from_wire(wire)
      assert meta.name == "run-01jz"
      assert meta.namespace == "crest-ci"
      assert meta.resource_version == "123"
      assert meta.uid == "abc"
      assert meta.annotations == %{"a" => "1"}
      assert meta.labels == %{"l" => "2"}

      assert [%OwnerReference{api_version: "v1", kind: "WorkflowRun", name: "parent", uid: "u-1"}] =
               meta.owner_references
    end

    test "from_wire rejects non-map input" do
      assert {:error, :invalid_object_meta} = ObjectMeta.from_wire("not a map")
    end

    test "from_wire rejects an invalid owner reference" do
      wire = %{
        "name" => "run-01jz",
        "ownerReferences" => [%{"apiVersion" => "v1", "kind" => "WorkflowRun"}]
      }

      assert {:error, :invalid_object_meta} = ObjectMeta.from_wire(wire)
    end

    test "from_wire defaults missing keys" do
      assert {:ok, meta} = ObjectMeta.from_wire(%{})
      assert meta.name == ""
      assert meta.owner_references == []
    end

    test "encode then decode round-trips an ObjectMeta with owner references" do
      {:ok, owner_ref} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "WorkflowRun",
          name: "run-01jz",
          uid: "uid-1"
        })

      {:ok, original} =
        ObjectMeta.new(%{
          annotations: %{"crest.dev/note" => "x"},
          creation_timestamp: "2026-07-05T00:00:00Z",
          labels: %{"crest.dev/run" => "01jz"},
          name: "run-01jz-j-build",
          namespace: "crest-ci",
          owner_references: [owner_ref],
          resource_version: "42",
          uid: "uid-2"
        })

      roundtripped =
        original
        |> ObjectMeta.to_wire()
        |> ObjectMeta.from_wire()

      assert {:ok, ^original} = roundtripped
    end

    test "encode then decode round-trips through actual JSON text" do
      {:ok, owner_ref} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "WorkflowRun",
          name: "run-01jz",
          uid: "uid-1"
        })

      {:ok, original} =
        ObjectMeta.new(%{
          name: "run-01jz-j-test",
          namespace: "crest-ci",
          resource_version: "7",
          uid: "uid-3",
          owner_references: [owner_ref]
        })

      json = Jason.encode!(original)
      decoded_wire = Jason.decode!(json)

      assert {:ok, ^original} = ObjectMeta.from_wire(decoded_wire)
    end

    test "encode then decode round-trips an ObjectMeta with no owner references" do
      {:ok, original} =
        ObjectMeta.new(%{
          annotations: %{"a" => "1"},
          creation_timestamp: "2026-07-05T00:00:00Z",
          labels: %{"l" => "2"},
          name: "run-01jz",
          namespace: "crest-ci",
          resource_version: "123",
          uid: "abc"
        })

      assert {:ok, ^original} =
               original
               |> ObjectMeta.to_wire()
               |> ObjectMeta.from_wire()
    end
  end
end
