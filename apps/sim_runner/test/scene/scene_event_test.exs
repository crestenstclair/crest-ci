defmodule SimRunner.Scene.SceneEventTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.SceneEvent

  describe "new/1" do
    test "builds a SceneEvent from valid fields" do
      assert {:ok, %SceneEvent{at_ms: 20_000, kind: :kill_leader, detail: %{}}} =
               SceneEvent.new(%{at_ms: 20_000, kind: :kill_leader})
    end

    test "accepts an explicit detail map" do
      assert {:ok, %SceneEvent{detail: %{count: 15}}} =
               SceneEvent.new(%{at_ms: 60_000, kind: :burst, detail: %{count: 15}})
    end

    test "defaults detail to an empty map" do
      assert {:ok, %SceneEvent{detail: %{}}} = SceneEvent.new(%{at_ms: 0, kind: :narrate})
    end

    for kind <- SceneEvent.kinds() do
      test "accepts kind #{inspect(kind)}" do
        assert {:ok, %SceneEvent{kind: unquote(kind)}} =
                 SceneEvent.new(%{at_ms: 1, kind: unquote(kind)})
      end
    end

    test "rejects an unknown kind" do
      assert {:error, :invalid_scene_event} = SceneEvent.new(%{at_ms: 0, kind: :teleport})
    end

    test "rejects a negative at_ms" do
      assert {:error, :invalid_scene_event} = SceneEvent.new(%{at_ms: -1, kind: :narrate})
    end

    test "rejects a non-integer at_ms" do
      assert {:error, :invalid_scene_event} = SceneEvent.new(%{at_ms: "20000", kind: :narrate})
    end

    test "rejects a missing at_ms" do
      assert {:error, :invalid_scene_event} = SceneEvent.new(%{kind: :narrate})
    end

    test "rejects a missing kind" do
      assert {:error, :invalid_scene_event} = SceneEvent.new(%{at_ms: 0})
    end

    test "rejects a non-map detail" do
      assert {:error, :invalid_scene_event} =
               SceneEvent.new(%{at_ms: 0, kind: :narrate, detail: "oops"})
    end

    test "rejects a non-map argument" do
      assert {:error, :invalid_scene_event} = SceneEvent.new("not a map")
    end
  end

  describe "from_wire/1 and to_wire/1" do
    test "decodes the Kubernetes-style wire shape" do
      wire = %{"atMs" => 35_000, "kind" => "KillGateway", "detail" => %{"replica" => 1}}

      assert {:ok, %SceneEvent{at_ms: 35_000, kind: :kill_gateway, detail: %{"replica" => 1}}} =
               SceneEvent.from_wire(wire)
    end

    test "defaults detail when absent from wire" do
      assert {:ok, %SceneEvent{detail: %{}}} =
               SceneEvent.from_wire(%{"atMs" => 0, "kind" => "Submit"})
    end

    test "rejects an unrecognized wire kind" do
      assert {:error, :invalid_scene_event} =
               SceneEvent.from_wire(%{"atMs" => 0, "kind" => "Explode"})
    end

    test "rejects a non-map wire payload" do
      assert {:error, :invalid_scene_event} = SceneEvent.from_wire("not a map")
    end

    test "round-trips through to_wire/from_wire for every kind" do
      for kind <- SceneEvent.kinds() do
        {:ok, event} = SceneEvent.new(%{at_ms: 42, kind: kind, detail: %{"a" => 1}})

        assert {:ok, ^event} = event |> SceneEvent.to_wire() |> SceneEvent.from_wire()
      end
    end
  end

  describe "Jason.Encoder" do
    test "encodes to the wire shape via Jason.encode!/1" do
      {:ok, event} = SceneEvent.new(%{at_ms: 20_000, kind: :kill_leader, detail: %{"x" => 1}})

      assert {:ok, decoded} = Jason.encode!(event) |> Jason.decode()
      assert decoded == %{"atMs" => 20_000, "kind" => "KillLeader", "detail" => %{"x" => 1}}
    end
  end
end
