defmodule Mix.Tasks.CrestCi.DemoE2e do
  @shortdoc "Boots the full M2 stack in one BEAM and runs the 3-job DAG through a gateway kill"

  @moduledoc """
  `mix crest_ci.demo_e2e` — boots mock-k8s, three controller instances,
  two gateway replicas (sharing one signing key), and a
  `CrestCiGateway.LocalFsBlobStore` rooted in a fresh temp dir, all inside
  this one BEAM. Submits one `WorkflowRun` with a hand-planned 3-job DAG
  (`build`, then `test-a` and `test-b` both needing `build`), kills one
  gateway replica while `test-a`/`test-b` are executing (observed via
  `WorkflowRun` status, never a timer), and verifies the result from
  authoritative store + blob-store state — never from client-side
  counters.

  Prints exactly one summary line:

      runs_succeeded=<n> jobs_completed=<n> duplicate_acquisitions=<n> gateway_killed=true log_chunks=<total> gapless=<true|false>

  Exits non-zero (via `Mix.raise/1`) if `runs_succeeded != 1`,
  `jobs_completed != 3`, `duplicate_acquisitions != 0`, or
  `gapless != true`.
  """

  use Mix.Task

  alias SimRunner.Demo.Orchestrator

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    metrics = Orchestrator.run()

    IO.puts(summary_line(metrics))

    check!(metrics)
  end

  defp summary_line(metrics) do
    "runs_succeeded=#{metrics.runs_succeeded} " <>
      "jobs_completed=#{metrics.jobs_completed} " <>
      "duplicate_acquisitions=#{metrics.duplicate_acquisitions} " <>
      "gateway_killed=#{metrics.gateway_killed} " <>
      "log_chunks=#{metrics.log_chunks} " <>
      "gapless=#{metrics.gapless}"
  end

  defp check!(%{runs_succeeded: runs_succeeded}) when runs_succeeded != 1 do
    Mix.raise("demo failed: runs_succeeded=#{runs_succeeded}, expected 1")
  end

  defp check!(%{jobs_completed: jobs_completed}) when jobs_completed != 3 do
    Mix.raise("demo failed: jobs_completed=#{jobs_completed}, expected 3")
  end

  defp check!(%{duplicate_acquisitions: duplicate_acquisitions})
       when duplicate_acquisitions != 0 do
    Mix.raise("demo failed: duplicate_acquisitions=#{duplicate_acquisitions}, expected 0")
  end

  defp check!(%{gapless: gapless}) when gapless != true do
    Mix.raise("demo failed: gapless=#{gapless}, expected true")
  end

  defp check!(_metrics), do: :ok
end
