defmodule CrestCiController.NeedsResolverTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{JobStatus, PlanJob}
  alias CrestCiController.NeedsResolver

  defp job!(fields), do: PlanJob.new(fields) |> elem(1)

  defp status!(fields), do: JobStatus.new(fields) |> elem(1)

  describe "resolve/2 — runnable classification" do
    test "a waiting job with no needs is runnable" do
      plan = [job!(%{key: "build"})]

      assert %{runnable_job_keys: ["build"], skip_job_keys: [], terminal: false, phase: nil} =
               NeedsResolver.resolve(plan, %{})
    end

    test "a waiting job whose sole need succeeded is runnable" do
      plan = [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]

      job_statuses = %{"build" => status!(%{phase: :succeeded})}

      result = NeedsResolver.resolve(plan, job_statuses)

      assert "test" in result.runnable_job_keys
      assert result.skip_job_keys == []
    end

    test "a job with no recorded status defaults to waiting and is treated accordingly" do
      # "build" has never been observed at all (missing from job_statuses),
      # so it defaults to :waiting -- dependents must stay unresolved, not runnable.
      plan = [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]

      result = NeedsResolver.resolve(plan, %{})

      assert result.runnable_job_keys == ["build"]
      assert result.skip_job_keys == []
    end
  end

  describe "resolve/2 — dependency-failure skip and unresolved-needs gating" do
    test "a job is skipped when a declared dependency failed" do
      plan = [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]

      job_statuses = %{"build" => status!(%{phase: :failed})}

      result = NeedsResolver.resolve(plan, job_statuses)

      assert result.skip_job_keys == ["test"]
      assert result.runnable_job_keys == []
    end

    test "a job is skipped when a declared dependency was itself skipped (cascade)" do
      plan = [
        job!(%{key: "build"}),
        job!(%{key: "test", needs: ["build"]}),
        job!(%{key: "deploy", needs: ["test"]})
      ]

      job_statuses = %{
        "build" => status!(%{phase: :failed}),
        "test" => status!(%{phase: :skipped})
      }

      result = NeedsResolver.resolve(plan, job_statuses)

      assert "deploy" in result.skip_job_keys
      assert result.runnable_job_keys == []
    end

    test "a job is neither runnable nor skipped while a dependency is still in flight" do
      plan = [job!(%{key: "build"}), job!(%{key: "test", needs: ["build"]})]

      for phase <- [:waiting, :queued, :assigned, :running] do
        job_statuses = %{"build" => status!(%{phase: phase})}
        result = NeedsResolver.resolve(plan, job_statuses)

        refute "test" in result.runnable_job_keys
        refute "test" in result.skip_job_keys
      end
    end

    test "a job with a mix of succeeded and unresolved needs stays unresolved, never runnable" do
      plan = [
        job!(%{key: "a"}),
        job!(%{key: "b"}),
        job!(%{key: "c", needs: ["a", "b"]})
      ]

      job_statuses = %{
        "a" => status!(%{phase: :succeeded}),
        "b" => status!(%{phase: :running})
      }

      result = NeedsResolver.resolve(plan, job_statuses)

      refute "c" in result.runnable_job_keys
      refute "c" in result.skip_job_keys
    end
  end

  describe "resolve/2 — jobs already beyond waiting are left alone (idempotency)" do
    test "a job already queued/assigned/running/terminal is never re-proposed" do
      plan = [job!(%{key: "build"})]

      for phase <- [:queued, :assigned, :running, :succeeded, :failed, :cancelled, :skipped] do
        job_statuses = %{"build" => status!(%{phase: phase})}
        result = NeedsResolver.resolve(plan, job_statuses)

        refute "build" in result.runnable_job_keys
        refute "build" in result.skip_job_keys
      end
    end
  end

  describe "resolve/2 — terminal detection" do
    test "empty plan is non-terminal with a nil phase" do
      assert %{terminal: false, phase: nil, runnable_job_keys: [], skip_job_keys: []} =
               NeedsResolver.resolve([], %{})
    end

    test "not terminal until every plan job has a terminal status" do
      plan = [job!(%{key: "a"}), job!(%{key: "b"})]

      job_statuses = %{"a" => status!(%{phase: :succeeded})}

      result = NeedsResolver.resolve(plan, job_statuses)

      assert result.terminal == false
      assert result.phase == nil
    end

    test "all succeeded/skipped -> terminal :succeeded" do
      plan = [job!(%{key: "a"}), job!(%{key: "b"})]

      job_statuses = %{
        "a" => status!(%{phase: :succeeded}),
        "b" => status!(%{phase: :skipped})
      }

      assert %{terminal: true, phase: :succeeded} = NeedsResolver.resolve(plan, job_statuses)
    end

    test "any failed -> terminal :failed, dominant over cancelled" do
      plan = [job!(%{key: "a"}), job!(%{key: "b"}), job!(%{key: "c"})]

      job_statuses = %{
        "a" => status!(%{phase: :failed}),
        "b" => status!(%{phase: :cancelled}),
        "c" => status!(%{phase: :succeeded})
      }

      assert %{terminal: true, phase: :failed} = NeedsResolver.resolve(plan, job_statuses)
    end

    test "any cancelled without a failed -> terminal :cancelled" do
      plan = [job!(%{key: "a"}), job!(%{key: "b"})]

      job_statuses = %{
        "a" => status!(%{phase: :cancelled}),
        "b" => status!(%{phase: :succeeded})
      }

      assert %{terminal: true, phase: :cancelled} = NeedsResolver.resolve(plan, job_statuses)
    end

    test "never proposes a transition out of a terminal phase for the same input" do
      plan = [job!(%{key: "a"})]
      job_statuses = %{"a" => status!(%{phase: :failed})}

      first = NeedsResolver.resolve(plan, job_statuses)
      second = NeedsResolver.resolve(plan, job_statuses)

      assert first == second
      assert first.terminal == true
      assert first.phase == :failed
    end
  end

  describe "resolve/2 — purity and determinism" do
    test "identical input always yields identical output" do
      plan = [
        job!(%{key: "build"}),
        job!(%{key: "test", needs: ["build"]}),
        job!(%{key: "deploy", needs: ["test"]})
      ]

      job_statuses = %{"build" => status!(%{phase: :succeeded})}

      results = for _ <- 1..25, do: NeedsResolver.resolve(plan, job_statuses)

      assert Enum.uniq(results) == [List.first(results)]
    end
  end
end
