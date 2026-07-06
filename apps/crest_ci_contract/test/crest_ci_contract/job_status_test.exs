defmodule CrestCiContract.JobStatusTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.JobStatus

  describe "phases/0" do
    test "is the closed enumeration declared for JobPhase" do
      assert JobStatus.phases() == [
               :waiting,
               :queued,
               :assigned,
               :running,
               :succeeded,
               :failed,
               :cancelled,
               :skipped
             ]
    end
  end

  describe "new/1" do
    test "builds a struct with sensible defaults when only phase is given" do
      assert {:ok, %JobStatus{} = status} = JobStatus.new(%{phase: :waiting})

      assert status.phase == :waiting
      assert status.assigned_runner == ""
      assert status.finished_at == ""
      assert status.log_chunks == 0
      assert status.outputs == %{}
      assert status.queued_at == ""
      assert status.started_at == ""
    end

    test "builds a struct with all fields populated" do
      assert {:ok, %JobStatus{} = status} =
               JobStatus.new(%{
                 assigned_runner: "runner-abc",
                 finished_at: "2026-07-05T12:00:00Z",
                 log_chunks: 42,
                 outputs: %{"artifact_url" => "https://example.test/a.tar"},
                 phase: :succeeded,
                 queued_at: "2026-07-05T11:00:00Z",
                 started_at: "2026-07-05T11:05:00Z"
               })

      assert status.assigned_runner == "runner-abc"
      assert status.finished_at == "2026-07-05T12:00:00Z"
      assert status.log_chunks == 42
      assert status.outputs == %{"artifact_url" => "https://example.test/a.tar"}
      assert status.phase == :succeeded
      assert status.queued_at == "2026-07-05T11:00:00Z"
      assert status.started_at == "2026-07-05T11:05:00Z"
    end

    for phase <- [
          :waiting,
          :queued,
          :assigned,
          :running,
          :succeeded,
          :failed,
          :cancelled,
          :skipped
        ] do
      test "accepts declared phase #{phase}" do
        assert {:ok, %JobStatus{phase: unquote(phase)}} = JobStatus.new(%{phase: unquote(phase)})
      end
    end

    test "rejects a phase outside the closed enumeration" do
      assert {:error, {:invalid_phase, :bogus}} = JobStatus.new(%{phase: :bogus})
    end
  end

  describe "update/2" do
    test "log_chunks stays at the higher value when an update carries a lower count" do
      {:ok, status} = JobStatus.new(%{phase: :running, log_chunks: 2})

      assert {:ok, updated} = JobStatus.update(status, %{log_chunks: 1})
      assert updated.log_chunks == 2
    end

    test "log_chunks advances when an update carries a higher count" do
      {:ok, status} = JobStatus.new(%{phase: :running, log_chunks: 2})

      assert {:ok, updated} = JobStatus.update(status, %{log_chunks: 5})
      assert updated.log_chunks == 5
    end

    test "log_chunks is unaffected when an update omits it" do
      {:ok, status} = JobStatus.new(%{phase: :running, log_chunks: 4})

      assert {:ok, updated} = JobStatus.update(status, %{phase: :succeeded})
      assert updated.log_chunks == 4
      assert updated.phase == :succeeded
    end

    test "replaying the same update sequence in any order converges to the same log_chunks" do
      {:ok, base} = JobStatus.new(%{phase: :running, log_chunks: 0})

      {:ok, forward} =
        base
        |> then(&(JobStatus.update(&1, %{log_chunks: 2}) |> elem(1)))
        |> then(&JobStatus.update(&1, %{log_chunks: 1}))

      {:ok, replayed} =
        base
        |> then(&(JobStatus.update(&1, %{log_chunks: 1}) |> elem(1)))
        |> then(&(JobStatus.update(&1, %{log_chunks: 2}) |> elem(1)))
        |> then(&JobStatus.update(&1, %{log_chunks: 1}))

      assert forward.log_chunks == 2
      assert replayed.log_chunks == 2
    end

    test "other fields are overwritten by the incoming value" do
      {:ok, status} = JobStatus.new(%{phase: :assigned, assigned_runner: "runner-1"})

      assert {:ok, updated} = JobStatus.update(status, %{assigned_runner: "runner-2"})
      assert updated.assigned_runner == "runner-2"
    end

    test "rejects an incoming phase outside the closed enumeration" do
      {:ok, status} = JobStatus.new(%{phase: :running})

      assert {:error, {:invalid_phase, :bogus}} = JobStatus.update(status, %{phase: :bogus})
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces camelCase keys with the phase as its declared wire string" do
      {:ok, status} =
        JobStatus.new(%{
          assigned_runner: "runner-1",
          finished_at: "",
          log_chunks: 3,
          outputs: %{"exit_code" => "0"},
          phase: :running,
          queued_at: "2026-07-05T10:00:00Z",
          started_at: "2026-07-05T10:01:00Z"
        })

      assert JobStatus.to_wire(status) == %{
               "assignedRunner" => "runner-1",
               "finishedAt" => "",
               "logChunks" => 3,
               "outputs" => %{"exit_code" => "0"},
               "phase" => "Running",
               "queuedAt" => "2026-07-05T10:00:00Z",
               "startedAt" => "2026-07-05T10:01:00Z"
             }
    end

    test "from_wire decodes a Kubernetes-shaped map back into a JobStatus" do
      wire = %{
        "assignedRunner" => "runner-2",
        "finishedAt" => "2026-07-05T12:30:00Z",
        "logChunks" => 7,
        "outputs" => %{"coverage" => "92%"},
        "phase" => "Succeeded",
        "queuedAt" => "2026-07-05T12:00:00Z",
        "startedAt" => "2026-07-05T12:05:00Z"
      }

      assert {:ok, %JobStatus{} = status} = JobStatus.from_wire(wire)
      assert status.phase == :succeeded
      assert status.assigned_runner == "runner-2"
      assert status.outputs == %{"coverage" => "92%"}
    end

    test "from_wire rejects a phase string outside the closed enumeration" do
      assert {:error, {:invalid_phase, "Bogus"}} =
               JobStatus.from_wire(%{"phase" => "Bogus"})
    end

    test "to_wire/from_wire round-trips without loss for every declared phase" do
      for phase <- JobStatus.phases() do
        {:ok, original} =
          JobStatus.new(%{
            assigned_runner: "runner-x",
            finished_at: "2026-01-01T00:00:00Z",
            log_chunks: 5,
            outputs: %{"k" => "v"},
            phase: phase,
            queued_at: "2026-01-01T00:00:00Z",
            started_at: "2026-01-01T00:00:00Z"
          })

        assert {:ok, roundtripped} = original |> JobStatus.to_wire() |> JobStatus.from_wire()
        assert roundtripped == original
      end
    end

    test "defaults missing wire fields (e.g. before assignment) rather than failing" do
      assert {:ok, %JobStatus{} = status} = JobStatus.from_wire(%{})
      assert status.phase == :waiting
      assert status.assigned_runner == ""
      assert status.outputs == %{}
    end
  end

  describe "Jason.Encoder" do
    test "Jason.encode!/1 serializes to the camelCase wire shape" do
      {:ok, status} = JobStatus.new(%{phase: :queued, queued_at: "2026-07-05T09:00:00Z"})

      encoded = Jason.encode!(status)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded == %{
               "assignedRunner" => "",
               "finishedAt" => "",
               "logChunks" => 0,
               "outputs" => %{},
               "phase" => "Queued",
               "queuedAt" => "2026-07-05T09:00:00Z",
               "startedAt" => ""
             }
    end
  end
end
