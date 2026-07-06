defmodule CrestCiContract.RunnerJobPhaseTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.RunnerJobPhase

  @expected_wire ~w(Queued Leased Acquired Completed Abandoned)

  @legal_edges [
    {:queued, :leased, :controller},
    {:queued, :leased, :gateway},
    {:leased, :acquired, :controller},
    {:leased, :acquired, :gateway},
    {:leased, :queued, :controller},
    {:acquired, :completed, :controller},
    {:acquired, :completed, :gateway},
    {:leased, :abandoned, :controller},
    {:acquired, :abandoned, :controller}
  ]

  @controller_only_edges [
    {:leased, :queued},
    {:leased, :abandoned},
    {:acquired, :abandoned}
  ]

  test "values/0 returns exactly the five declared phases" do
    assert length(RunnerJobPhase.values()) == 5

    assert Enum.sort(RunnerJobPhase.values()) ==
             Enum.sort([:queued, :leased, :acquired, :completed, :abandoned])
  end

  test "valid?/1 accepts every declared phase and rejects everything else" do
    for phase <- RunnerJobPhase.values() do
      assert RunnerJobPhase.valid?(phase)
    end

    refute RunnerJobPhase.valid?(:bogus)
    refute RunnerJobPhase.valid?("Queued")
    refute RunnerJobPhase.valid?(nil)
  end

  test "to_wire/1 renders the exact Kubernetes wire strings" do
    assert RunnerJobPhase.to_wire(:queued) == "Queued"
    assert RunnerJobPhase.to_wire(:leased) == "Leased"
    assert RunnerJobPhase.to_wire(:acquired) == "Acquired"
    assert RunnerJobPhase.to_wire(:completed) == "Completed"
    assert RunnerJobPhase.to_wire(:abandoned) == "Abandoned"
  end

  test "from_wire/1 parses every declared wire string back to its atom" do
    for wire <- @expected_wire do
      assert {:ok, atom} = RunnerJobPhase.from_wire(wire)
      assert RunnerJobPhase.to_wire(atom) == wire
    end
  end

  test "to_wire/1 and from_wire/1 round-trip for every declared phase" do
    for phase <- RunnerJobPhase.values() do
      assert {:ok, ^phase} = phase |> RunnerJobPhase.to_wire() |> RunnerJobPhase.from_wire()
    end
  end

  test "from_wire/1 rejects out-of-enum strings distinctly from success" do
    assert RunnerJobPhase.from_wire("queued") == {:error, :invalid_runner_job_phase}
    assert RunnerJobPhase.from_wire("InProgress") == {:error, :invalid_runner_job_phase}
    assert RunnerJobPhase.from_wire("") == {:error, :invalid_runner_job_phase}
  end

  test "from_wire/1 rejects non-string input without raising" do
    assert RunnerJobPhase.from_wire(nil) == {:error, :invalid_runner_job_phase}
    assert RunnerJobPhase.from_wire(:queued) == {:error, :invalid_runner_job_phase}
    assert RunnerJobPhase.from_wire(123) == {:error, :invalid_runner_job_phase}
  end

  test "legal_transition?/3 accepts exactly the declared legal edges for the declared actors" do
    for {from, to, actor} <- @legal_edges do
      assert RunnerJobPhase.legal_transition?(from, to, actor),
             "expected #{from} -> #{to} to be legal for #{actor}"
    end
  end

  test "legal_transition?/3 rejects every edge not in the declared transition table" do
    for from <- RunnerJobPhase.values(),
        to <- RunnerJobPhase.values(),
        actor <- [:controller, :gateway],
        not Enum.member?(@legal_edges, {from, to, actor}) do
      refute RunnerJobPhase.legal_transition?(from, to, actor),
             "expected #{from} -> #{to} (#{actor}) to be illegal"
    end
  end

  test "controller-only edges (lease expiry, abandonment) refuse the gateway actor" do
    for {from, to} <- @controller_only_edges do
      assert RunnerJobPhase.legal_transition?(from, to, :controller)

      refute RunnerJobPhase.legal_transition?(from, to, :gateway),
             "expected #{from} -> #{to} to be refused for :gateway"
    end
  end

  test "no phase ever transitions to itself" do
    for phase <- RunnerJobPhase.values(), actor <- [:controller, :gateway] do
      refute RunnerJobPhase.legal_transition?(phase, phase, actor)
    end
  end

  test "Completed and Abandoned are terminal: no outgoing edges exist" do
    for terminal <- [:completed, :abandoned],
        to <- RunnerJobPhase.values(),
        actor <- [:controller, :gateway] do
      refute RunnerJobPhase.legal_transition?(terminal, to, actor),
             "expected #{terminal} to have no outgoing transitions"
    end
  end

  test "transition/3 returns {:ok, to} for legal edges and {:error, :illegal_transition} otherwise" do
    assert RunnerJobPhase.transition(:queued, :leased, :gateway) == {:ok, :leased}
    assert RunnerJobPhase.transition(:leased, :acquired, :gateway) == {:ok, :acquired}
    assert RunnerJobPhase.transition(:acquired, :completed, :gateway) == {:ok, :completed}

    assert RunnerJobPhase.transition(:leased, :queued, :controller) == {:ok, :queued}

    assert RunnerJobPhase.transition(:leased, :queued, :gateway) ==
             {:error, :illegal_transition}

    assert RunnerJobPhase.transition(:leased, :abandoned, :controller) == {:ok, :abandoned}

    assert RunnerJobPhase.transition(:leased, :abandoned, :gateway) ==
             {:error, :illegal_transition}

    assert RunnerJobPhase.transition(:acquired, :abandoned, :controller) == {:ok, :abandoned}

    assert RunnerJobPhase.transition(:acquired, :abandoned, :gateway) ==
             {:error, :illegal_transition}

    assert RunnerJobPhase.transition(:queued, :acquired, :controller) ==
             {:error, :illegal_transition}

    assert RunnerJobPhase.transition(:completed, :queued, :controller) ==
             {:error, :illegal_transition}
  end
end
