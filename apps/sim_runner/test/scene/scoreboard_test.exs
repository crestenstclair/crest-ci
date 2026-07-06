defmodule SimRunner.Scene.ScoreboardTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.Scoreboard

  describe "new/1" do
    test "defaults every field to 0 when given an empty map" do
      assert {:ok, scoreboard} = Scoreboard.new(%{})

      assert scoreboard == %Scoreboard{
               archive_gaps: 0,
               cache_hits: 0,
               controller_failover_gap_ms: 0,
               controller_failovers: 0,
               duplicate_acquisitions: 0,
               gateway_failovers: 0,
               rehomed_runners: 0,
               runs_failed: 0,
               runs_succeeded: 0
             }
    end

    test "accepts all nine fields as non-negative integers" do
      assert {:ok, scoreboard} =
               Scoreboard.new(%{
                 archive_gaps: 0,
                 cache_hits: 1,
                 controller_failover_gap_ms: 1250,
                 controller_failovers: 2,
                 duplicate_acquisitions: 3,
                 gateway_failovers: 4,
                 rehomed_runners: 5,
                 runs_failed: 1,
                 runs_succeeded: 9
               })

      assert scoreboard.cache_hits == 1
      assert scoreboard.controller_failover_gap_ms == 1250
      assert scoreboard.runs_succeeded == 9
    end

    test "rejects a negative field rather than clamping it" do
      assert {:error, {:invalid_field, :runs_failed, -1}} =
               Scoreboard.new(%{runs_failed: -1})
    end

    test "rejects a non-integer field" do
      assert {:error, {:invalid_field, :cache_hits, "3"}} =
               Scoreboard.new(%{cache_hits: "3"})
    end

    test "ignores keys outside the declared field set" do
      assert {:ok, scoreboard} = Scoreboard.new(%{bogus: 42})
      refute Map.has_key?(scoreboard, :bogus)
    end
  end

  describe "fields/0" do
    test "returns all nine counters in declaration order" do
      assert Scoreboard.fields() == [
               :archive_gaps,
               :cache_hits,
               :controller_failover_gap_ms,
               :controller_failovers,
               :duplicate_acquisitions,
               :gateway_failovers,
               :rehomed_runners,
               :runs_failed,
               :runs_succeeded
             ]
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips through the camelCase wire shape" do
      {:ok, scoreboard} =
        Scoreboard.new(%{
          archive_gaps: 1,
          cache_hits: 2,
          controller_failover_gap_ms: 3400,
          controller_failovers: 3,
          duplicate_acquisitions: 4,
          gateway_failovers: 5,
          rehomed_runners: 6,
          runs_failed: 1,
          runs_succeeded: 7
        })

      wire = Scoreboard.to_wire(scoreboard)

      assert wire == %{
               "archiveGaps" => 1,
               "cacheHits" => 2,
               "controllerFailoverGapMs" => 3400,
               "controllerFailovers" => 3,
               "duplicateAcquisitions" => 4,
               "gatewayFailovers" => 5,
               "rehomedRunners" => 6,
               "runsFailed" => 1,
               "runsSucceeded" => 7
             }

      assert Scoreboard.from_wire(wire) == {:ok, scoreboard}
    end

    test "from_wire/1 defaults missing keys to 0" do
      assert {:ok, scoreboard} = Scoreboard.from_wire(%{"cacheHits" => 5})
      assert scoreboard.cache_hits == 5
      assert scoreboard.runs_succeeded == 0
    end

    test "from_wire/1 rejects a negative value under its wire key" do
      assert {:error, {:invalid_field, :archive_gaps, -2}} =
               Scoreboard.from_wire(%{"archiveGaps" => -2})
    end
  end

  describe "Jason.Encoder" do
    test "encodes to the same shape as to_wire/1" do
      {:ok, scoreboard} = Scoreboard.new(%{runs_succeeded: 2})

      assert Jason.encode!(scoreboard) ==
               scoreboard |> Scoreboard.to_wire() |> Jason.encode!()
    end
  end
end
