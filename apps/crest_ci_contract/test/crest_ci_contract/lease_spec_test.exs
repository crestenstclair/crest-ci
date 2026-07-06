defmodule CrestCiContract.LeaseSpecTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.LeaseSpec

  @valid_wire %{
    "acquireTime" => "2026-07-05T00:00:00Z",
    "holderIdentity" => "controller-0",
    "leaseDurationSeconds" => 15,
    "leaseTransitions" => 3,
    "renewTime" => "2026-07-05T00:00:10Z"
  }

  describe "new/5" do
    test "builds a LeaseSpec from well-shaped values" do
      assert {:ok, spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 15,
                 3,
                 "2026-07-05T00:00:10Z"
               )

      assert spec.acquire_time == "2026-07-05T00:00:00Z"
      assert spec.holder_identity == "controller-0"
      assert spec.lease_duration_seconds == 15
      assert spec.lease_transitions == 3
      assert spec.renew_time == "2026-07-05T00:00:10Z"
    end

    test "rejects non-binary timestamp/identity fields" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(nil, "controller-0", 15, 3, "2026-07-05T00:00:10Z")

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("2026-07-05T00:00:00Z", :controller, 15, 3, "2026-07-05T00:00:10Z")
    end

    test "rejects non-integer counter fields" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 "15",
                 3,
                 "2026-07-05T00:00:10Z"
               )

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 15,
                 3.0,
                 "2026-07-05T00:00:10Z"
               )
    end

    test "rejects a zero or negative lease_duration_seconds" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("2026-07-05T00:00:00Z", "controller-0", 0, 3, "2026-07-05T00:00:10Z")

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 -1,
                 3,
                 "2026-07-05T00:00:10Z"
               )
    end

    test "rejects a negative lease_transitions" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 15,
                 -1,
                 "2026-07-05T00:00:10Z"
               )
    end

    test "accepts a zero lease_transitions (no transitions yet)" do
      assert {:ok, spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 15,
                 0,
                 "2026-07-05T00:00:10Z"
               )

      assert spec.lease_transitions == 0
    end

    test "rejects an empty holder_identity" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("2026-07-05T00:00:00Z", "", 15, 3, "2026-07-05T00:00:10Z")
    end

    test "rejects an empty or non-RFC3339 acquire_time/renew_time" do
      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("", "controller-0", 15, 3, "2026-07-05T00:00:10Z")

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("not-a-timestamp", "controller-0", 15, 3, "2026-07-05T00:00:10Z")

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new("2026-07-05T00:00:00Z", "controller-0", 15, 3, "")

      assert {:error, :invalid_lease_spec} =
               LeaseSpec.new(
                 "2026-07-05T00:00:00Z",
                 "controller-0",
                 15,
                 3,
                 "not-a-timestamp"
               )
    end
  end

  describe "to_wire/1" do
    test "renders the exact Kubernetes camelCase wire map" do
      {:ok, spec} =
        LeaseSpec.new("2026-07-05T00:00:00Z", "controller-0", 15, 3, "2026-07-05T00:00:10Z")

      assert LeaseSpec.to_wire(spec) == @valid_wire
    end
  end

  describe "from_wire/1" do
    test "parses a well-shaped wire map" do
      assert {:ok, spec} = LeaseSpec.from_wire(@valid_wire)
      assert spec.acquire_time == "2026-07-05T00:00:00Z"
      assert spec.holder_identity == "controller-0"
      assert spec.lease_duration_seconds == 15
      assert spec.lease_transitions == 3
      assert spec.renew_time == "2026-07-05T00:00:10Z"
    end

    test "round-trips through Jason encode/decode" do
      {:ok, spec} =
        LeaseSpec.new("2026-07-05T00:00:00Z", "controller-0", 15, 3, "2026-07-05T00:00:10Z")

      wire_json = Jason.encode!(LeaseSpec.to_wire(spec))
      decoded = Jason.decode!(wire_json)

      assert {:ok, ^spec} = LeaseSpec.from_wire(decoded)
    end

    test "rejects a wire map missing a required field" do
      missing = Map.delete(@valid_wire, "holderIdentity")
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(missing)
    end

    test "rejects a wire map with a field of the wrong type" do
      wrong_type = Map.put(@valid_wire, "leaseDurationSeconds", "15")
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(wrong_type)

      wrong_type2 = Map.put(@valid_wire, "acquireTime", 12_345)
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(wrong_type2)
    end

    test "rejects non-map input" do
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(nil)
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire("not a map")
    end

    test "rejects a wire map failing well-formedness rules" do
      zero_duration = Map.put(@valid_wire, "leaseDurationSeconds", 0)
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(zero_duration)

      negative_transitions = Map.put(@valid_wire, "leaseTransitions", -1)
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(negative_transitions)

      empty_identity = Map.put(@valid_wire, "holderIdentity", "")
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(empty_identity)

      bad_timestamp = Map.put(@valid_wire, "acquireTime", "not-a-timestamp")
      assert {:error, :invalid_lease_spec} = LeaseSpec.from_wire(bad_timestamp)
    end
  end
end
