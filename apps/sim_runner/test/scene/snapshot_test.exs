defmodule SimRunner.Scene.SnapshotTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.Snapshot

  describe "new/1" do
    test "builds a struct with all-zero/empty defaults when no fields are given" do
      assert {:ok, %Snapshot{} = snapshot} = Snapshot.new(%{})

      assert snapshot.acquisitions == 0
      assert snapshot.cache_hits == 0
      assert snapshot.cache_misses == 0
      assert snapshot.chunk_count == 0
      assert snapshot.done == 0
      assert snapshot.duplicate_acquisitions == 0
      assert snapshot.elapsed_ms == 0
      assert snapshot.failovers == []
      assert snapshot.gateways == []
      assert snapshot.leader == ""
      assert snapshot.lease_remaining_s == 0
      assert snapshot.leased == 0
      assert snapshot.queued == 0
      assert snapshot.running == 0
      assert snapshot.runs == []
    end

    test "builds a struct with all fields populated" do
      fields = %{
        acquisitions: 12,
        cache_hits: 5,
        cache_misses: 2,
        chunk_count: 40,
        done: 3,
        duplicate_acquisitions: 1,
        elapsed_ms: 15_000,
        failovers: [%{"kind" => "controller", "at_ms" => 4200}],
        gateways: [%{"id" => "gw-1", "state" => "active"}],
        leader: "controller-a",
        lease_remaining_s: 12,
        leased: 2,
        queued: 4,
        running: 6,
        runs: [%{"name" => "run-1", "phase" => "Running"}]
      }

      assert {:ok, %Snapshot{} = snapshot} = Snapshot.new(fields)

      assert snapshot.acquisitions == 12
      assert snapshot.cache_hits == 5
      assert snapshot.cache_misses == 2
      assert snapshot.chunk_count == 40
      assert snapshot.done == 3
      assert snapshot.duplicate_acquisitions == 1
      assert snapshot.elapsed_ms == 15_000
      assert snapshot.failovers == [%{"kind" => "controller", "at_ms" => 4200}]
      assert snapshot.gateways == [%{"id" => "gw-1", "state" => "active"}]
      assert snapshot.leader == "controller-a"
      assert snapshot.lease_remaining_s == 12
      assert snapshot.leased == 2
      assert snapshot.queued == 4
      assert snapshot.running == 6
      assert snapshot.runs == [%{"name" => "run-1", "phase" => "Running"}]
    end

    test "allows lease_remaining_s to go negative (brief window before sweep)" do
      assert {:ok, %Snapshot{lease_remaining_s: -3}} = Snapshot.new(%{lease_remaining_s: -3})
    end

    test "rejects a negative counter field" do
      assert {:error, {:invalid_field, :acquisitions, -1}} = Snapshot.new(%{acquisitions: -1})
    end

    test "rejects a non-integer counter field" do
      assert {:error, {:invalid_field, :queued, "3"}} = Snapshot.new(%{queued: "3"})
    end

    test "rejects a non-integer lease_remaining_s" do
      assert {:error, {:invalid_field, :lease_remaining_s, "12"}} =
               Snapshot.new(%{lease_remaining_s: "12"})
    end

    test "rejects a non-string leader" do
      assert {:error, {:invalid_field, :leader, 42}} = Snapshot.new(%{leader: 42})
    end

    test "rejects a non-list value for a list field" do
      assert {:error, {:invalid_field, :runs, "nope"}} = Snapshot.new(%{runs: "nope"})
    end

    test "rejects a list field containing a non-map element" do
      assert {:error, {:invalid_field, :gateways, ["not-a-map"]}} =
               Snapshot.new(%{gateways: ["not-a-map"]})
    end

    test "validates fields in declaration order, returning the first violation" do
      assert {:error, {:invalid_field, :acquisitions, -1}} =
               Snapshot.new(%{acquisitions: -1, cache_hits: -2})
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces the declared camelCase wire shape" do
      {:ok, snapshot} =
        Snapshot.new(%{
          acquisitions: 1,
          cache_hits: 2,
          cache_misses: 3,
          chunk_count: 4,
          done: 5,
          duplicate_acquisitions: 6,
          elapsed_ms: 7,
          failovers: [%{"a" => 1}],
          gateways: [%{"b" => 2}],
          leader: "controller-a",
          lease_remaining_s: 8,
          leased: 9,
          queued: 10,
          running: 11,
          runs: [%{"c" => 3}]
        })

      assert Snapshot.to_wire(snapshot) == %{
               "acquisitions" => 1,
               "cacheHits" => 2,
               "cacheMisses" => 3,
               "chunkCount" => 4,
               "done" => 5,
               "duplicateAcquisitions" => 6,
               "elapsedMs" => 7,
               "failovers" => [%{"a" => 1}],
               "gateways" => [%{"b" => 2}],
               "leader" => "controller-a",
               "leaseRemainingS" => 8,
               "leased" => 9,
               "queued" => 10,
               "running" => 11,
               "runs" => [%{"c" => 3}]
             }
    end

    test "from_wire/1 round-trips through to_wire/1" do
      wire = %{
        "acquisitions" => 1,
        "cacheHits" => 2,
        "cacheMisses" => 3,
        "chunkCount" => 4,
        "done" => 5,
        "duplicateAcquisitions" => 6,
        "elapsedMs" => 7,
        "failovers" => [%{"a" => 1}],
        "gateways" => [%{"b" => 2}],
        "leader" => "controller-a",
        "leaseRemainingS" => 8,
        "leased" => 9,
        "queued" => 10,
        "running" => 11,
        "runs" => [%{"c" => 3}]
      }

      assert {:ok, snapshot} = Snapshot.from_wire(wire)
      assert Snapshot.to_wire(snapshot) == wire
    end

    test "from_wire/1 defaults missing keys" do
      assert {:ok, %Snapshot{} = snapshot} = Snapshot.from_wire(%{})
      assert snapshot == %Snapshot{}
    end

    test "from_wire/1 propagates validation errors" do
      assert {:error, {:invalid_field, :done, -1}} = Snapshot.from_wire(%{"done" => -1})
    end
  end

  describe "Jason.Encoder" do
    test "encodes directly via Jason.encode!/1 using the wire shape" do
      {:ok, snapshot} = Snapshot.new(%{leader: "controller-a", queued: 2})

      encoded = Jason.encode!(snapshot)
      decoded = Jason.decode!(encoded)

      assert decoded == Snapshot.to_wire(snapshot)
    end
  end
end
