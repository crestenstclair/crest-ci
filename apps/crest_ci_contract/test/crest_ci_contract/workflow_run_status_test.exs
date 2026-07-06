defmodule CrestCiContract.WorkflowRunStatusTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{JobStatus, WorkflowRunPhase, WorkflowRunStatus}

  defp job(phase) do
    {:ok, status} = JobStatus.new(%{phase: phase})
    status
  end

  describe "phases/0" do
    test "delegates to the closed enumeration declared for WorkflowRunPhase" do
      assert Enum.sort(WorkflowRunStatus.phases()) ==
               Enum.sort([:pending, :queued, :running, :succeeded, :failed, :cancelled])

      assert WorkflowRunStatus.phases() == WorkflowRunPhase.values()
    end
  end

  describe "new/1 and derive_phase/1" do
    test "no jobs at all derives :pending" do
      status = WorkflowRunStatus.new(%{})
      assert status.phase == :pending
      assert status.jobs == %{}
    end

    test "new/0 defaults to an empty jobs map" do
      status = WorkflowRunStatus.new()
      assert status.phase == :pending
      assert status.jobs == %{}
    end

    test "any failed job derives :failed regardless of other job phases" do
      jobs = %{"build" => job(:succeeded), "test" => job(:failed), "lint" => job(:running)}
      assert WorkflowRunStatus.new(jobs).phase == :failed
    end

    test "any cancelled job (with none failed) derives :cancelled" do
      jobs = %{"build" => job(:succeeded), "test" => job(:cancelled)}
      assert WorkflowRunStatus.new(jobs).phase == :cancelled
    end

    test "every job succeeded or skipped derives :succeeded" do
      jobs = %{"build" => job(:succeeded), "docs" => job(:skipped)}
      assert WorkflowRunStatus.new(jobs).phase == :succeeded
    end

    test "any running or assigned job (with no failure/cancellation) derives :running" do
      jobs = %{"build" => job(:succeeded), "test" => job(:running)}
      assert WorkflowRunStatus.new(jobs).phase == :running

      jobs2 = %{"build" => job(:queued), "test" => job(:assigned)}
      assert WorkflowRunStatus.new(jobs2).phase == :running
    end

    test "any queued job with nothing further along derives :queued" do
      jobs = %{"build" => job(:waiting), "test" => job(:queued)}
      assert WorkflowRunStatus.new(jobs).phase == :queued
    end

    test "every job still waiting derives :pending" do
      jobs = %{"build" => job(:waiting), "test" => job(:waiting)}
      assert WorkflowRunStatus.new(jobs).phase == :pending
    end

    test "derive_phase/1 is pure and deterministic for identical input" do
      jobs = %{"build" => job(:running), "test" => job(:queued)}
      assert WorkflowRunStatus.derive_phase(jobs) == WorkflowRunStatus.derive_phase(jobs)
    end
  end

  describe "update_jobs/2" do
    test "recomputes phase from the new jobs map when not currently terminal" do
      status = WorkflowRunStatus.new(%{"build" => job(:queued)})
      assert status.phase == :queued

      updated = WorkflowRunStatus.update_jobs(status, %{"build" => job(:running)})
      assert updated.phase == :running
      assert updated.jobs == %{"build" => job(:running)}
    end

    test "terminal phases are absorbing: further job-map changes do not move phase off terminal" do
      status = WorkflowRunStatus.new(%{"build" => job(:failed)})
      assert status.phase == :failed

      # even if the jobs map is replaced with something that would derive
      # to a completely different phase on its own, the aggregate stays failed
      still_failed = WorkflowRunStatus.update_jobs(status, %{"build" => job(:waiting)})
      assert still_failed.phase == :failed
      assert still_failed.jobs == %{"build" => job(:waiting)}
    end

    for terminal_phase <- [:succeeded, :failed, :cancelled] do
      test "#{terminal_phase} never transitions further via update_jobs" do
        {:ok, terminal_job} = JobStatus.new(%{phase: unquote(terminal_phase)})
        status = WorkflowRunStatus.new(%{"only" => terminal_job})
        assert status.phase == unquote(terminal_phase)

        moved = WorkflowRunStatus.update_jobs(status, %{"only" => job(:running)})
        assert moved.phase == unquote(terminal_phase)
      end
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "to_wire produces camelCase-shaped jobs and the phase as its declared wire string" do
      status = WorkflowRunStatus.new(%{"build" => job(:running)})

      assert WorkflowRunStatus.to_wire(status) == %{
               "jobs" => %{"build" => JobStatus.to_wire(job(:running))},
               "phase" => "Running"
             }
    end

    test "from_wire decodes a Kubernetes-shaped map back into a WorkflowRunStatus" do
      wire = %{
        "jobs" => %{"build" => JobStatus.to_wire(job(:queued))},
        "phase" => "Queued"
      }

      assert {:ok, %WorkflowRunStatus{} = status} = WorkflowRunStatus.from_wire(wire)
      assert status.phase == :queued
      assert status.jobs == %{"build" => job(:queued)}
    end

    test "from_wire recomputes a non-terminal wire phase rather than trusting it blindly" do
      wire = %{
        "jobs" => %{"build" => JobStatus.to_wire(job(:failed))},
        # wire claims :pending but the job is failed -> should recompute to :failed
        "phase" => "Pending"
      }

      assert {:ok, %WorkflowRunStatus{phase: :failed}} = WorkflowRunStatus.from_wire(wire)
    end

    test "from_wire preserves an already-terminal wire phase (absorbing) even if jobs alone would derive differently" do
      wire = %{
        "jobs" => %{"build" => JobStatus.to_wire(job(:waiting))},
        "phase" => "Succeeded"
      }

      assert {:ok, %WorkflowRunStatus{phase: :succeeded}} = WorkflowRunStatus.from_wire(wire)
    end

    test "from_wire rejects a phase string outside the closed enumeration" do
      assert {:error, :invalid_workflow_run_phase} =
               WorkflowRunStatus.from_wire(%{"jobs" => %{}, "phase" => "Bogus"})
    end

    test "from_wire rejects a job phase string outside its closed enumeration" do
      wire = %{"jobs" => %{"build" => %{"phase" => "Bogus"}}, "phase" => "Pending"}
      assert {:error, {:invalid_job_phase, "build", _reason}} = WorkflowRunStatus.from_wire(wire)
    end

    test "defaults missing wire fields rather than failing" do
      assert {:ok, %WorkflowRunStatus{} = status} = WorkflowRunStatus.from_wire(%{})
      assert status.phase == :pending
      assert status.jobs == %{}
    end

    test "to_wire/from_wire round-trips terminal phases without loss (jobs alone would derive differently)" do
      for phase <- Enum.filter(WorkflowRunPhase.values(), &WorkflowRunPhase.terminal?/1) do
        status = %{WorkflowRunStatus.new(%{"only" => job(:waiting)}) | phase: phase}

        assert {:ok, roundtripped} =
                 status |> WorkflowRunStatus.to_wire() |> WorkflowRunStatus.from_wire()

        assert roundtripped == status
      end
    end

    test "to_wire/from_wire round-trips non-terminal statuses whose stored phase matches the jobs derivation" do
      for {phase, jobs} <- [
            {:pending, %{"only" => job(:waiting)}},
            {:queued, %{"only" => job(:queued)}},
            {:running, %{"only" => job(:running)}}
          ] do
        status = WorkflowRunStatus.new(jobs)
        assert status.phase == phase

        assert {:ok, roundtripped} =
                 status |> WorkflowRunStatus.to_wire() |> WorkflowRunStatus.from_wire()

        assert roundtripped == status
      end
    end
  end

  describe "put_plan/2 and mark_plan_failed/2" do
    test "put_plan/2 records a plan without touching jobs or phase" do
      status = WorkflowRunStatus.new(%{"build" => job(:queued)})
      {:ok, plan_job} = CrestCiContract.PlanJob.new(%{key: "build"})

      updated = WorkflowRunStatus.put_plan(status, [plan_job])

      assert updated.plan == [plan_job]
      assert updated.jobs == status.jobs
      assert updated.phase == status.phase
    end

    test "mark_plan_failed/2 moves a non-terminal status to :failed and records the reason" do
      status = WorkflowRunStatus.new(%{})

      updated = WorkflowRunStatus.mark_plan_failed(status, "boom")

      assert updated.phase == :failed
      assert updated.plan_error == "boom"
    end

    test "mark_plan_failed/2 never moves an already-terminal status off its terminal phase" do
      status = WorkflowRunStatus.new(%{"build" => job(:succeeded)})
      assert status.phase == :succeeded

      updated = WorkflowRunStatus.mark_plan_failed(status, "boom")

      assert updated.phase == :succeeded
      assert updated.plan_error == "boom"
    end

    test "to_wire omits plan/planError when at their defaults (byte-identical to before these fields existed)" do
      status = WorkflowRunStatus.new(%{"build" => job(:running)})

      assert WorkflowRunStatus.to_wire(status) == %{
               "jobs" => %{"build" => JobStatus.to_wire(job(:running))},
               "phase" => "Running"
             }
    end

    test "to_wire/from_wire round-trips a status carrying a derived plan and a recorded plan error" do
      {:ok, plan_job} = CrestCiContract.PlanJob.new(%{key: "build"})

      status =
        WorkflowRunStatus.new(%{})
        |> WorkflowRunStatus.put_plan([plan_job])
        |> WorkflowRunStatus.mark_plan_failed("boom")

      wire = WorkflowRunStatus.to_wire(status)
      assert wire["plan"] == [CrestCiContract.PlanJob.to_wire(plan_job)]
      assert wire["planError"] == "boom"

      assert {:ok, roundtripped} = WorkflowRunStatus.from_wire(wire)
      assert roundtripped == status
    end
  end

  describe "Jason.Encoder" do
    test "Jason.encode!/1 serializes to the camelCase wire shape" do
      status = WorkflowRunStatus.new(%{"build" => job(:succeeded)})

      encoded = Jason.encode!(status)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded == %{
               "jobs" => %{"build" => JobStatus.to_wire(job(:succeeded))},
               "phase" => "Succeeded"
             }
    end
  end
end
