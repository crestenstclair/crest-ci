defmodule CrestCiContract.RunnerJobStatusTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.RunnerJobStatus

  describe "phases/0" do
    test "is the closed enumeration declared for RunnerJobPhase" do
      assert RunnerJobStatus.phases() == [:queued, :leased, :acquired, :completed, :abandoned]
    end
  end

  describe "new/1" do
    test "builds a struct with sensible defaults when only phase is given" do
      assert {:ok, %RunnerJobStatus{} = status} = RunnerJobStatus.new(%{phase: :queued})

      assert status.phase == :queued
      assert status.acquired_at == ""
      assert status.lease_expires_at == ""
      assert status.leased_by == ""
      assert status.result == ""
    end

    test "builds a struct with all fields populated" do
      assert {:ok, %RunnerJobStatus{} = status} =
               RunnerJobStatus.new(%{
                 acquired_at: "2026-07-05T12:00:00Z",
                 lease_expires_at: "2026-07-05T12:05:00Z",
                 leased_by: "runner-abc",
                 phase: :acquired,
                 result: ""
               })

      assert status.acquired_at == "2026-07-05T12:00:00Z"
      assert status.lease_expires_at == "2026-07-05T12:05:00Z"
      assert status.leased_by == "runner-abc"
      assert status.phase == :acquired
      assert status.result == ""
    end

    for phase <- [:queued, :leased, :acquired, :completed, :abandoned] do
      test "accepts declared phase #{phase}" do
        assert {:ok, %RunnerJobStatus{phase: unquote(phase)}} =
                 RunnerJobStatus.new(%{phase: unquote(phase)})
      end
    end

    test "rejects a phase outside the closed enumeration" do
      assert {:error, {:invalid_phase, :bogus}} = RunnerJobStatus.new(%{phase: :bogus})
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces camelCase keys with the phase as its declared wire string" do
      {:ok, status} =
        RunnerJobStatus.new(%{
          acquired_at: "",
          lease_expires_at: "2026-07-05T10:05:00Z",
          leased_by: "runner-1",
          phase: :leased,
          result: ""
        })

      assert RunnerJobStatus.to_wire(status) == %{
               "acquiredAt" => "",
               "leaseExpiresAt" => "2026-07-05T10:05:00Z",
               "leasedBy" => "runner-1",
               "phase" => "Leased",
               "result" => ""
             }
    end

    test "from_wire decodes a Kubernetes-shaped map back into a RunnerJobStatus" do
      wire = %{
        "acquiredAt" => "2026-07-05T12:30:00Z",
        "leaseExpiresAt" => "2026-07-05T12:35:00Z",
        "leasedBy" => "runner-2",
        "phase" => "Acquired",
        "result" => ""
      }

      assert {:ok, %RunnerJobStatus{} = status} = RunnerJobStatus.from_wire(wire)
      assert status.phase == :acquired
      assert status.leased_by == "runner-2"
      assert status.acquired_at == "2026-07-05T12:30:00Z"
    end

    test "from_wire rejects a phase string outside the closed enumeration" do
      assert {:error, {:invalid_phase, "Bogus"}} =
               RunnerJobStatus.from_wire(%{"phase" => "Bogus"})
    end

    test "to_wire/from_wire round-trips without loss for every declared phase" do
      for phase <- RunnerJobStatus.phases() do
        {:ok, original} =
          RunnerJobStatus.new(%{
            acquired_at: "2026-01-01T00:00:00Z",
            lease_expires_at: "2026-01-01T00:05:00Z",
            leased_by: "runner-x",
            phase: phase,
            result: "some-result"
          })

        assert {:ok, roundtripped} =
                 original |> RunnerJobStatus.to_wire() |> RunnerJobStatus.from_wire()

        assert roundtripped == original
      end
    end

    test "defaults missing wire fields (e.g. before assignment) rather than failing" do
      assert {:ok, %RunnerJobStatus{} = status} = RunnerJobStatus.from_wire(%{})
      assert status.phase == :queued
      assert status.acquired_at == ""
      assert status.leased_by == ""
    end
  end

  describe "Jason.Encoder" do
    test "Jason.encode!/1 serializes to the camelCase wire shape" do
      {:ok, status} =
        RunnerJobStatus.new(%{phase: :queued, lease_expires_at: "2026-07-05T09:10:00Z"})

      encoded = Jason.encode!(status)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded == %{
               "acquiredAt" => "",
               "leaseExpiresAt" => "2026-07-05T09:10:00Z",
               "leasedBy" => "",
               "phase" => "Queued",
               "result" => ""
             }
    end
  end

  describe "legal_transition?/2" do
    test "accepts every documented legal edge" do
      assert RunnerJobStatus.legal_transition?(:queued, :leased)
      assert RunnerJobStatus.legal_transition?(:leased, :acquired)
      assert RunnerJobStatus.legal_transition?(:leased, :queued)
      assert RunnerJobStatus.legal_transition?(:acquired, :completed)
      assert RunnerJobStatus.legal_transition?(:leased, :abandoned)
      assert RunnerJobStatus.legal_transition?(:acquired, :abandoned)
    end

    test "rejects transitions not in the declared phase machine" do
      refute RunnerJobStatus.legal_transition?(:queued, :acquired)
      refute RunnerJobStatus.legal_transition?(:completed, :queued)
      refute RunnerJobStatus.legal_transition?(:abandoned, :queued)
      refute RunnerJobStatus.legal_transition?(:queued, :queued)
      refute RunnerJobStatus.legal_transition?(:completed, :abandoned)
    end
  end
end
