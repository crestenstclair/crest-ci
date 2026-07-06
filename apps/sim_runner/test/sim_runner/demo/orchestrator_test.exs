defmodule SimRunner.Demo.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SimRunner.Demo.Orchestrator

  # The M2 exit criterion, in-process: one WorkflowRun with a needs DAG
  # flows through controller -> queue -> gateway -> SimRunner -> completion,
  # across a gateway replica kill, with every metric computed from
  # authoritative state (never a client-side counter). Tighter timeouts
  # than the production Mix task's defaults, since everything here runs
  # against in-memory/local collaborators with no real network latency.
  test "3-job DAG completes through a gateway replica kill with zero duplicate acquisitions and a gapless log" do
    root = Path.join(System.tmp_dir!(), "demo_e2e_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    metrics =
      Orchestrator.run(blob_root: root, running_timeout_ms: 5_000, terminal_timeout_ms: 5_000)

    assert metrics.runs_succeeded == 1
    assert metrics.jobs_completed == 3
    assert metrics.duplicate_acquisitions == 0
    assert metrics.gateway_killed == true
    assert metrics.gapless == true
    assert metrics.log_chunks > 0
  end
end
