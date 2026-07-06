defmodule SimRunner.Demo.ResultsOrchestratorTest do
  use ExUnit.Case, async: false

  alias SimRunner.Demo.ResultsOrchestrator

  # The results exit criterion, in-process: two sequential WorkflowRuns
  # each flow through their own fresh controller -> queue -> gateway ->
  # SimRunner -> completion boot, proving a real artifact round-trip
  # (upload then download, verified by digest) and a cache miss on run 1
  # followed by a hit on run 2 under the same key — every metric computed
  # from authoritative state (never a client-side counter). Tighter
  # timeouts than the production Mix task's defaults, since everything
  # here runs against in-memory/local collaborators with no real network
  # latency.
  test "two sequential runs verify artifact upload/download and cache miss-then-hit with a gapless archive" do
    blob_root =
      Path.join(System.tmp_dir!(), "demo_results_test_blob_#{System.unique_integer([:positive])}")

    cache_root =
      Path.join(
        System.tmp_dir!(),
        "demo_results_test_cache_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf!(blob_root)
      File.rm_rf!(cache_root)
    end)

    metrics =
      ResultsOrchestrator.run(
        blob_root: blob_root,
        cache_root: cache_root,
        terminal_timeout_ms: 5_000
      )

    assert metrics.runs_succeeded == 2
    assert metrics.artifacts_verified == 2
    assert metrics.cache_hit_second_run == true
    assert metrics.archive_gaps == 0
  end
end
