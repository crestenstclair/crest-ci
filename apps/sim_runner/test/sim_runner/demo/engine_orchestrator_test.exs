defmodule SimRunner.Demo.EngineOrchestratorTest do
  use ExUnit.Case, async: false

  alias SimRunner.Demo.EngineOrchestrator

  # The M4 engine exit criterion, in-process: a WorkflowRun carrying a
  # real workflowYaml (no hand-built plan) flows through the engine
  # (parse -> context -> plan) and then the M2 stack (controller ->
  # queue -> gateway -> SimRunner -> completion), with every metric
  # computed from authoritative state. Tighter timeouts than the
  # production Mix task's defaults, since everything here runs against
  # in-memory/local collaborators with no real network latency.
  test "a workflowYaml-driven WorkflowRun plans, executes, and re-plans deterministically" do
    metrics =
      EngineOrchestrator.run(running_timeout_ms: 5_000, terminal_timeout_ms: 5_000)

    assert metrics.planned_jobs == 4
    assert metrics.excluded_by_if == 1
    assert metrics.runs_succeeded == 1
    assert metrics.plan_deterministic == true
  end
end
