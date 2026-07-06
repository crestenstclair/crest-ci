defmodule Mix.Tasks.CrestCi.DemoResults do
  @shortdoc "Runs two sequential WorkflowRuns end-to-end, proving artifact upload/verify and cache miss-then-hit"

  @moduledoc """
  `mix crest_ci.demo_results` — boots the full in-BEAM stack (mock-k8s,
  three controller instances per run, two gateway replicas per run, and
  `CrestCiGateway.LocalFsBlobStore`-backed stores rooted in fresh temp
  dirs) and executes TWO sequential `WorkflowRun`s whose job includes
  steps of kind `upload_artifact` (a deterministic ~64KiB payload) and
  `cache_restore` + `cache_save` under the same cache key.

  Run 1 observes a cache miss then saves; run 2 observes a cache hit.
  After both runs, verifies from authoritative state (never a
  client-side counter): both runs Succeeded; the artifact from each run
  downloads byte-identical to what was uploaded (digest comparison);
  run 2's `cache_restore` was a hit; every job's archive is gapless
  (the same compaction-verification approach
  `mix crest_ci.demo_e2e` uses).

  Prints exactly one summary line:

      runs_succeeded=<n> artifacts_verified=<n> cache_hit_second_run=<true|false> archive_gaps=<n>

  Exits non-zero (via `Mix.raise/1`) unless `runs_succeeded == 2`,
  `artifacts_verified == 2`, `cache_hit_second_run == true`, and
  `archive_gaps == 0`.
  """

  use Mix.Task

  alias SimRunner.Demo.ResultsOrchestrator

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    metrics = ResultsOrchestrator.run()

    IO.puts(summary_line(metrics))

    check!(metrics)
  end

  defp summary_line(metrics) do
    "runs_succeeded=#{metrics.runs_succeeded} " <>
      "artifacts_verified=#{metrics.artifacts_verified} " <>
      "cache_hit_second_run=#{metrics.cache_hit_second_run} " <>
      "archive_gaps=#{metrics.archive_gaps}"
  end

  defp check!(%{runs_succeeded: runs_succeeded}) when runs_succeeded != 2 do
    Mix.raise("demo failed: runs_succeeded=#{runs_succeeded}, expected 2")
  end

  defp check!(%{artifacts_verified: artifacts_verified}) when artifacts_verified != 2 do
    Mix.raise("demo failed: artifacts_verified=#{artifacts_verified}, expected 2")
  end

  defp check!(%{cache_hit_second_run: cache_hit_second_run}) when cache_hit_second_run != true do
    Mix.raise("demo failed: cache_hit_second_run=#{cache_hit_second_run}, expected true")
  end

  defp check!(%{archive_gaps: archive_gaps}) when archive_gaps != 0 do
    Mix.raise("demo failed: archive_gaps=#{archive_gaps}, expected 0")
  end

  defp check!(_metrics), do: :ok
end
