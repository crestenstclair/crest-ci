defmodule CrestCiContract.WorkflowRunPhaseTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.WorkflowRunPhase

  @expected_wire ~w(Pending Queued Running Succeeded Failed Cancelled)

  test "values/0 returns exactly the six declared phases" do
    assert length(WorkflowRunPhase.values()) == 6

    assert Enum.sort(WorkflowRunPhase.values()) ==
             Enum.sort([:pending, :queued, :running, :succeeded, :failed, :cancelled])
  end

  test "valid?/1 accepts every declared phase and rejects everything else" do
    for phase <- WorkflowRunPhase.values() do
      assert WorkflowRunPhase.valid?(phase)
    end

    refute WorkflowRunPhase.valid?(:bogus)
    refute WorkflowRunPhase.valid?("Pending")
    refute WorkflowRunPhase.valid?(nil)
  end

  test "to_wire/1 renders the exact Kubernetes wire strings" do
    assert WorkflowRunPhase.to_wire(:pending) == "Pending"
    assert WorkflowRunPhase.to_wire(:queued) == "Queued"
    assert WorkflowRunPhase.to_wire(:running) == "Running"
    assert WorkflowRunPhase.to_wire(:succeeded) == "Succeeded"
    assert WorkflowRunPhase.to_wire(:failed) == "Failed"
    assert WorkflowRunPhase.to_wire(:cancelled) == "Cancelled"
  end

  test "from_wire/1 parses every declared wire string back to its atom" do
    for wire <- @expected_wire do
      assert {:ok, atom} = WorkflowRunPhase.from_wire(wire)
      assert WorkflowRunPhase.to_wire(atom) == wire
    end
  end

  test "to_wire/1 and from_wire/1 round-trip for every declared phase" do
    for phase <- WorkflowRunPhase.values() do
      assert {:ok, ^phase} = phase |> WorkflowRunPhase.to_wire() |> WorkflowRunPhase.from_wire()
    end
  end

  test "from_wire/1 rejects out-of-enum strings distinctly from success" do
    assert WorkflowRunPhase.from_wire("pending") == {:error, :invalid_workflow_run_phase}
    assert WorkflowRunPhase.from_wire("InProgress") == {:error, :invalid_workflow_run_phase}
    assert WorkflowRunPhase.from_wire("") == {:error, :invalid_workflow_run_phase}
  end

  test "from_wire/1 rejects non-string input without raising" do
    assert WorkflowRunPhase.from_wire(nil) == {:error, :invalid_workflow_run_phase}
    assert WorkflowRunPhase.from_wire(:pending) == {:error, :invalid_workflow_run_phase}
    assert WorkflowRunPhase.from_wire(123) == {:error, :invalid_workflow_run_phase}
  end

  test "terminal?/1 is true only for Succeeded, Failed, Cancelled" do
    assert WorkflowRunPhase.terminal?(:succeeded)
    assert WorkflowRunPhase.terminal?(:failed)
    assert WorkflowRunPhase.terminal?(:cancelled)

    refute WorkflowRunPhase.terminal?(:pending)
    refute WorkflowRunPhase.terminal?(:queued)
    refute WorkflowRunPhase.terminal?(:running)
  end

  test "transition_allowed?/2 forbids every transition away from a terminal phase" do
    for terminal <- [:succeeded, :failed, :cancelled],
        other <- WorkflowRunPhase.values(),
        other != terminal do
      refute WorkflowRunPhase.transition_allowed?(terminal, other),
             "expected #{terminal} -> #{other} to be disallowed"
    end
  end

  test "transition_allowed?/2 allows a terminal phase to remain itself" do
    for terminal <- [:succeeded, :failed, :cancelled] do
      assert WorkflowRunPhase.transition_allowed?(terminal, terminal)
    end
  end

  test "transition_allowed?/2 permits transitions originating from non-terminal phases" do
    for from <- [:pending, :queued, :running], to <- WorkflowRunPhase.values() do
      assert WorkflowRunPhase.transition_allowed?(from, to)
    end
  end
end
