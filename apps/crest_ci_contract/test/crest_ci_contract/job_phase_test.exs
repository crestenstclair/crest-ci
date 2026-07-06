defmodule CrestCiContract.JobPhaseTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.JobPhase

  @expected_wire ~w(Waiting Queued Assigned Running Succeeded Failed Cancelled Skipped)

  test "values/0 returns exactly the eight declared phases" do
    assert length(JobPhase.values()) == 8

    assert Enum.sort(JobPhase.values()) ==
             Enum.sort([
               :waiting,
               :queued,
               :assigned,
               :running,
               :succeeded,
               :failed,
               :cancelled,
               :skipped
             ])
  end

  test "valid?/1 accepts every declared phase and rejects everything else" do
    for phase <- JobPhase.values() do
      assert JobPhase.valid?(phase)
    end

    refute JobPhase.valid?(:bogus)
    refute JobPhase.valid?("Waiting")
    refute JobPhase.valid?(nil)
  end

  test "to_wire/1 renders the exact Kubernetes wire strings" do
    assert JobPhase.to_wire(:waiting) == "Waiting"
    assert JobPhase.to_wire(:queued) == "Queued"
    assert JobPhase.to_wire(:assigned) == "Assigned"
    assert JobPhase.to_wire(:running) == "Running"
    assert JobPhase.to_wire(:succeeded) == "Succeeded"
    assert JobPhase.to_wire(:failed) == "Failed"
    assert JobPhase.to_wire(:cancelled) == "Cancelled"
    assert JobPhase.to_wire(:skipped) == "Skipped"
  end

  test "from_wire/1 parses every declared wire string back to its atom" do
    for wire <- @expected_wire do
      assert {:ok, atom} = JobPhase.from_wire(wire)
      assert JobPhase.to_wire(atom) == wire
    end
  end

  test "to_wire/1 and from_wire/1 round-trip for every declared phase" do
    for phase <- JobPhase.values() do
      assert {:ok, ^phase} = phase |> JobPhase.to_wire() |> JobPhase.from_wire()
    end
  end

  test "from_wire/1 rejects out-of-enum strings distinctly from success" do
    assert JobPhase.from_wire("waiting") == {:error, :invalid_job_phase}
    assert JobPhase.from_wire("InProgress") == {:error, :invalid_job_phase}
    assert JobPhase.from_wire("") == {:error, :invalid_job_phase}
  end

  test "from_wire/1 rejects non-string input without raising" do
    assert JobPhase.from_wire(nil) == {:error, :invalid_job_phase}
    assert JobPhase.from_wire(:waiting) == {:error, :invalid_job_phase}
    assert JobPhase.from_wire(123) == {:error, :invalid_job_phase}
  end
end
