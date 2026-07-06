defmodule SimRunner.Scene.ChaosTimelineTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.ChaosTimeline
  alias SimRunner.Scene.SceneEvent

  describe "default/0" do
    test "kills the leader ~t+20s, a gateway ~t+35s, and bursts ~t+60s, in order" do
      [first, second, third] = ChaosTimeline.default()

      assert %SceneEvent{at_ms: 20_000, kind: :kill_leader} = first
      assert %SceneEvent{at_ms: 35_000, kind: :kill_gateway} = second
      assert %SceneEvent{at_ms: 60_000, kind: :burst} = third
    end
  end

  describe "due/3" do
    test "returns no events before any of them are due" do
      assert {[], fired} = ChaosTimeline.due(ChaosTimeline.default(), 0, MapSet.new())
      assert MapSet.size(fired) == 0
    end

    test "an event becomes due exactly at its at_ms (boundary is inclusive)" do
      timeline = ChaosTimeline.default()
      {due, fired} = ChaosTimeline.due(timeline, 20_000, MapSet.new())

      assert [%SceneEvent{kind: :kill_leader}] = due
      assert MapSet.member?(fired, 0)
      refute MapSet.member?(fired, 1)
      refute MapSet.member?(fired, 2)
    end

    test "an event one millisecond before its at_ms is not yet due" do
      timeline = ChaosTimeline.default()
      {due, fired} = ChaosTimeline.due(timeline, 19_999, MapSet.new())

      assert due == []
      assert MapSet.size(fired) == 0
    end

    test "multiple events due at once are returned sorted by at_ms ascending" do
      timeline = ChaosTimeline.default()
      {due, _fired} = ChaosTimeline.due(timeline, 60_000, MapSet.new())

      assert [
               %SceneEvent{kind: :kill_leader, at_ms: 20_000},
               %SceneEvent{kind: :kill_gateway, at_ms: 35_000},
               %SceneEvent{kind: :burst, at_ms: 60_000}
             ] = due
    end

    test "already-fired events are never returned again" do
      timeline = ChaosTimeline.default()
      already_fired = MapSet.new([0])

      {due, fired} = ChaosTimeline.due(timeline, 60_000, already_fired)

      refute Enum.any?(due, &(&1.kind == :kill_leader))
      assert Enum.any?(due, &(&1.kind == :kill_gateway))
      assert Enum.any?(due, &(&1.kind == :burst))
      assert MapSet.equal?(fired, MapSet.new([0, 1, 2]))
    end

    test "is idempotent: replaying with the previously returned already_fired yields nothing new" do
      timeline = ChaosTimeline.default()

      {first_due, fired_after_first} = ChaosTimeline.due(timeline, 60_000, MapSet.new())
      assert length(first_due) == 3

      {second_due, fired_after_second} = ChaosTimeline.due(timeline, 60_000, fired_after_first)

      assert second_due == []
      assert MapSet.equal?(fired_after_second, fired_after_first)
    end

    test "replaying at a later elapsed_ms only returns newly-due events" do
      timeline = ChaosTimeline.default()

      {_due, fired_after_first} = ChaosTimeline.due(timeline, 20_000, MapSet.new())
      {due_second, fired_after_second} = ChaosTimeline.due(timeline, 35_000, fired_after_first)

      assert [%SceneEvent{kind: :kill_gateway}] = due_second
      assert MapSet.equal?(fired_after_second, MapSet.new([0, 1]))
    end

    test "defaults already_fired to an empty set when omitted" do
      timeline = ChaosTimeline.default()
      {due, _fired} = ChaosTimeline.due(timeline, 20_000)

      assert [%SceneEvent{kind: :kill_leader}] = due
    end

    test "supports a compressed, test-injected timeline instead of the default" do
      compressed = [
        %SceneEvent{at_ms: 0, kind: :narrate, detail: %{message: "scene start"}},
        %SceneEvent{at_ms: 5, kind: :kill_leader, detail: %{}},
        %SceneEvent{at_ms: 10, kind: :burst, detail: %{count: 2}}
      ]

      {due, fired} = ChaosTimeline.due(compressed, 7, MapSet.new())

      assert [%SceneEvent{kind: :narrate}, %SceneEvent{kind: :kill_leader}] = due
      assert MapSet.equal?(fired, MapSet.new([0, 1]))
    end

    test "reconciliation is order-independent: replaying events out of order converges to the same state" do
      timeline = ChaosTimeline.default()

      {_due_a, fired_a} = ChaosTimeline.due(timeline, 35_000, MapSet.new())
      {_due_a2, fired_a} = ChaosTimeline.due(timeline, 60_000, fired_a)

      {_due_b, fired_b} = ChaosTimeline.due(timeline, 60_000, MapSet.new())

      assert MapSet.equal?(fired_a, fired_b)
    end

    test "an empty timeline never has anything due" do
      assert {[], fired} = ChaosTimeline.due([], 999_999, MapSet.new())
      assert MapSet.size(fired) == 0
    end
  end
end
