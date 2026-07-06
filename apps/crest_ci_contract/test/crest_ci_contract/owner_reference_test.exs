defmodule CrestCiContract.OwnerReferenceTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.OwnerReference

  describe "new/1" do
    test "builds a struct when all four fields are present non-empty binaries" do
      assert {:ok, %OwnerReference{} = ref} =
               OwnerReference.new(%{
                 api_version: "crest.dev/v1",
                 kind: "WorkflowRun",
                 name: "run-01hzzz",
                 uid: "abc-123"
               })

      assert ref.api_version == "crest.dev/v1"
      assert ref.kind == "WorkflowRun"
      assert ref.name == "run-01hzzz"
      assert ref.uid == "abc-123"
    end

    test "rejects a fields map missing any required key" do
      assert {:error, :invalid_owner_reference} =
               OwnerReference.new(%{kind: "WorkflowRun", name: "run-01hzzz", uid: "abc-123"})

      assert {:error, :invalid_owner_reference} =
               OwnerReference.new(%{
                 api_version: "crest.dev/v1",
                 name: "run-01hzzz",
                 uid: "abc-123"
               })
    end

    test "rejects an empty-string field" do
      assert {:error, :invalid_owner_reference} =
               OwnerReference.new(%{
                 api_version: "",
                 kind: "WorkflowRun",
                 name: "run-01hzzz",
                 uid: "abc-123"
               })
    end

    test "rejects non-binary field values" do
      assert {:error, :invalid_owner_reference} =
               OwnerReference.new(%{
                 api_version: "crest.dev/v1",
                 kind: "WorkflowRun",
                 name: "run-01hzzz",
                 uid: 123
               })
    end

    test "rejects non-map input" do
      assert {:error, :invalid_owner_reference} = OwnerReference.new("not a map")
      assert {:error, :invalid_owner_reference} = OwnerReference.new(nil)
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces the declared camelCase wire shape" do
      {:ok, ref} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "RunnerJob",
          name: "run-01hzzz-j-build",
          uid: "uid-1"
        })

      assert OwnerReference.to_wire(ref) == %{
               "apiVersion" => "crest.dev/v1",
               "kind" => "RunnerJob",
               "name" => "run-01hzzz-j-build",
               "uid" => "uid-1"
             }
    end

    test "from_wire decodes a Kubernetes-shaped map back into an OwnerReference" do
      wire = %{
        "apiVersion" => "crest.dev/v1",
        "kind" => "WorkflowRun",
        "name" => "run-01hzzz",
        "uid" => "abc-123"
      }

      assert {:ok, %OwnerReference{} = ref} = OwnerReference.from_wire(wire)
      assert ref.api_version == "crest.dev/v1"
      assert ref.kind == "WorkflowRun"
      assert ref.name == "run-01hzzz"
      assert ref.uid == "abc-123"
    end

    test "from_wire rejects a map missing a required field" do
      assert {:error, :invalid_owner_reference} =
               OwnerReference.from_wire(%{
                 "apiVersion" => "crest.dev/v1",
                 "kind" => "WorkflowRun"
               })
    end

    test "from_wire rejects non-map input" do
      assert {:error, :invalid_owner_reference} = OwnerReference.from_wire("nope")
    end

    test "encode then decode reproduces the original struct (round-trip)" do
      {:ok, original} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "WorkflowRun",
          name: "run-01hzzz",
          uid: "abc-123"
        })

      assert {:ok, roundtripped} =
               original |> OwnerReference.to_wire() |> OwnerReference.from_wire()

      assert roundtripped == original
    end
  end

  describe "Jason.Encoder" do
    test "Jason.encode!/1 serializes to the camelCase wire shape" do
      {:ok, ref} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "WorkflowRun",
          name: "run-01hzzz",
          uid: "abc-123"
        })

      encoded = Jason.encode!(ref)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded == %{
               "apiVersion" => "crest.dev/v1",
               "kind" => "WorkflowRun",
               "name" => "run-01hzzz",
               "uid" => "abc-123"
             }
    end

    test "Jason.encode! then OwnerReference.from_wire round-trips through JSON" do
      {:ok, original} =
        OwnerReference.new(%{
          api_version: "crest.dev/v1",
          kind: "RunnerJob",
          name: "run-01hzzz-j-build",
          uid: "uid-9"
        })

      roundtripped =
        original
        |> Jason.encode!()
        |> Jason.decode!()
        |> OwnerReference.from_wire()

      assert {:ok, ^original} = roundtripped
    end
  end
end
