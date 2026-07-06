defmodule Mix.Tasks.CrestCi.DemoEngine do
  @shortdoc "Drives a real workflow YAML through the engine (parse/plan) and the M2 stack (execute) end-to-end"

  @moduledoc """
  `mix crest_ci.demo_engine` — boots mock-k8s, one controller instance,
  and one gateway replica, all inside this one BEAM, and submits a single
  `WorkflowRun` whose `spec` carries a real GitHub Actions `workflowYaml`
  document and NO hand-built `plan`. The engine
  (`domainService.Engine.WorkflowParser` -> `.GithubContext` ->
  `.Planner`) is what turns that YAML into the executed job DAG, not this
  demo — see `SimRunner.Demo.EngineOrchestrator` for the full scenario and
  every measured assertion.

  The fixture workflow declares 5 jobs: `lint` and `build` run with no
  dependencies (in parallel); `test` needs `build` and carries a
  job-level `if` on `github.ref` that evaluates TRUE for the submitted
  event; `package` needs `[lint, test]`; `deploy` needs `[package]` and
  carries a job-level `if` on `github.ref` that evaluates FALSE for the
  submitted event, so it must be excluded from the plan entirely.

  Prints exactly one summary line:

      planned_jobs=<n> excluded_by_if=<n> runs_succeeded=<n> plan_deterministic=<true|false>

  Exits non-zero (via `Mix.raise/1`) unless `planned_jobs == 4`,
  `excluded_by_if == 1`, `runs_succeeded == 1`, and
  `plan_deterministic == true`.
  """

  use Mix.Task

  alias SimRunner.Demo.EngineOrchestrator

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    metrics = EngineOrchestrator.run()

    IO.puts(summary_line(metrics))

    check!(metrics)
  end

  defp summary_line(metrics) do
    "planned_jobs=#{metrics.planned_jobs} " <>
      "excluded_by_if=#{metrics.excluded_by_if} " <>
      "runs_succeeded=#{metrics.runs_succeeded} " <>
      "plan_deterministic=#{metrics.plan_deterministic}"
  end

  defp check!(%{planned_jobs: planned_jobs}) when planned_jobs != 4 do
    Mix.raise("demo failed: planned_jobs=#{planned_jobs}, expected 4")
  end

  defp check!(%{excluded_by_if: excluded_by_if}) when excluded_by_if != 1 do
    Mix.raise("demo failed: excluded_by_if=#{excluded_by_if}, expected 1")
  end

  defp check!(%{runs_succeeded: runs_succeeded}) when runs_succeeded != 1 do
    Mix.raise("demo failed: runs_succeeded=#{runs_succeeded}, expected 1")
  end

  defp check!(%{plan_deterministic: plan_deterministic}) when plan_deterministic != true do
    Mix.raise("demo failed: plan_deterministic=#{plan_deterministic}, expected true")
  end

  defp check!(_metrics), do: :ok
end
