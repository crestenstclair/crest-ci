defmodule CrestCiController.Engine.PlannerGoldenTest do
  @moduledoc """
  Golden-fixture proof for the Engine C1 slice: real GitHub-Actions-shaped
  workflow YAML through `WorkflowParser.parse/1` and `Planner.plan/2`,
  compared against hand-derived expectations.

  Six fixtures under `test/engine/fixtures/`:

    1. `chain.yaml`          — build -> test -> deploy, with a job-level
       `if` referencing `github.ref`.
    2. `env_anchors.yaml`    — YAML anchors/merge keys (`&job_defaults` /
       `<<: *job_defaults`) plus workflow -> job `env` merging (job wins),
       proven indirectly through job-level `if` conditions that reference
       `env.*`.
    3. `diamond.yaml`        — a four-job fan-out/fan-in diamond.
    4. `unknown_needs.yaml`  — a `needs` reference to a job that does not
       exist.
    5. `cyclic_needs.yaml`   — a `needs` cycle between two jobs.
    6. `unknown_keys.yaml`   — unrecognized top-level and job-level keys
       that must plan successfully while surfacing warnings.

  For fixtures 1-3 the plan is computed twice from the same
  `(WorkflowDefinition, GithubContext)` input and the two plans are
  compared via their `Jason`-encoded wire shape for byte-identical
  equality — this is what proves the engine's determinism invariant, not
  merely that the plan "looks right" once.

  Every check below is *measured* rather than asserted inline, so a
  single mismatched fixture never hides the state of the other five: the
  suite always prints exactly one summary line,
  `fixtures=<n> plan_mismatches=<n> determinism_violations=<n>`, before
  asserting both counts are zero.
  """

  use ExUnit.Case, async: true

  alias CrestCiContract.PlanJob
  alias CrestCiController.Engine.{GithubContext, Planner, WorkflowParser}

  @fixtures_dir Path.join(__DIR__, "fixtures")

  @push_context_fields %{
    actor: "octocat",
    event: %{},
    event_name: "push",
    ref: "refs/heads/main",
    repository: "octo/repo",
    sha: "deadbeef0000000000000000000000000000000"
  }

  test "parse+plan golden fixtures are correct and deterministic" do
    fixture_checks = [
      chain_fixture(),
      env_anchors_fixture(),
      diamond_fixture(),
      unknown_needs_fixture(),
      cyclic_needs_fixture(),
      unknown_keys_fixture()
    ]

    fixtures = length(fixture_checks)
    plan_mismatches = fixture_checks |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    determinism_violations = fixture_checks |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    IO.puts(
      "fixtures=#{fixtures} plan_mismatches=#{plan_mismatches} determinism_violations=#{determinism_violations}"
    )

    assert plan_mismatches == 0
    assert determinism_violations == 0
  end

  # -- Fixture 1: build -> test -> deploy chain, job-level if on github.ref --

  defp chain_fixture do
    {definition, _warnings} = parse_fixture!("chain.yaml")
    context = push_context()

    expected = [
      {"build", [], ["ubuntu-latest"]},
      {"test", ["build"], ["ubuntu-latest"]},
      {"deploy", ["test"], ["ubuntu-latest"]}
    ]

    expect_ok_plan(definition, context, expected)
  end

  # -- Fixture 2: YAML anchors/merge keys + workflow/job env merge --

  defp env_anchors_fixture do
    {definition, _warnings} = parse_fixture!("env_anchors.yaml")
    context = push_context()

    expected = [
      {"alpha", [], ["ubuntu-latest"]},
      {"beta", [], ["ubuntu-latest"]}
    ]

    expect_ok_plan(definition, context, expected)
  end

  # -- Fixture 3: fan-out/fan-in diamond (four jobs) --

  defp diamond_fixture do
    {definition, _warnings} = parse_fixture!("diamond.yaml")
    context = push_context()

    expected = [
      {"setup", [], ["ubuntu-latest"]},
      {"integration_tests", ["setup"], ["ubuntu-latest"]},
      {"unit_tests", ["setup"], ["ubuntu-latest"]},
      {"release", ["unit_tests", "integration_tests"], ["ubuntu-latest"]}
    ]

    expect_ok_plan(definition, context, expected)
  end

  # -- Fixture 4: needs references a job that does not exist --

  defp unknown_needs_fixture do
    {definition, _warnings} = parse_fixture!("unknown_needs.yaml")
    context = push_context()

    expect_plan_error(definition, context, ["test", "build_missing"])
  end

  # -- Fixture 5: needs cycle between two jobs --

  defp cyclic_needs_fixture do
    {definition, _warnings} = parse_fixture!("cyclic_needs.yaml")
    context = push_context()

    expect_plan_error(definition, context, ["a", "b"])
  end

  # -- Fixture 6: unknown top-level/job keys -> warnings, plan still ok --

  defp unknown_keys_fixture do
    {definition, warnings} = parse_fixture!("unknown_keys.yaml")
    context = push_context()

    case Planner.plan(definition, context) do
      {:ok, plan} ->
        has_build = Enum.any?(plan, fn %PlanJob{key: key} -> key == "build" end)

        if warnings != [] and has_build do
          {0, 0}
        else
          {1, 0}
        end

      _other ->
        {1, 0}
    end
  end

  # -- Shared helpers --------------------------------------------------------

  @spec push_context() :: GithubContext.t()
  defp push_context do
    {:ok, context} = GithubContext.new(@push_context_fields)
    context
  end

  @spec parse_fixture!(String.t()) :: {term(), list()}
  defp parse_fixture!(filename) do
    yaml = File.read!(Path.join(@fixtures_dir, filename))

    case WorkflowParser.parse(yaml) do
      {:ok, definition, warnings} ->
        {definition, warnings}

      other ->
        flunk("expected {:ok, definition, warnings} parsing #{filename}, got #{inspect(other)}")
    end
  end

  # Runs `Planner.plan/2` twice against identical input and returns
  # `{plan_mismatch, determinism_violation}` (each `0` or `1`):
  # `plan_mismatch` is `1` when the first plan's `{key, needs, runs_on}`
  # tuples (in order) don't equal `expected`; `determinism_violation` is
  # `1` when the two plans don't encode to byte-identical JSON.
  @spec expect_ok_plan(term(), GithubContext.t(), [{String.t(), [String.t()], [String.t()]}]) ::
          {0 | 1, 0 | 1}
  defp expect_ok_plan(definition, context, expected) do
    case {Planner.plan(definition, context), Planner.plan(definition, context)} do
      {{:ok, plan_a}, {:ok, plan_b}} ->
        mismatch = if jobs_match?(plan_a, expected), do: 0, else: 1
        violation = if Jason.encode!(plan_a) == Jason.encode!(plan_b), do: 0, else: 1
        {mismatch, violation}

      _other ->
        {1, 1}
    end
  end

  # Returns `{plan_mismatch, 0}` — `0` when `Planner.plan/2` returns
  # `{:error, reason}` and `inspect(reason)` names every id in
  # `expected_job_ids`; `1` otherwise. Determinism is not measured for
  # error fixtures (only the ok-plan fixtures 1-3 assert it).
  @spec expect_plan_error(term(), GithubContext.t(), [String.t()]) :: {0 | 1, 0}
  defp expect_plan_error(definition, context, expected_job_ids) do
    case Planner.plan(definition, context) do
      {:error, reason} ->
        rendered = inspect(reason)

        if Enum.all?(expected_job_ids, &String.contains?(rendered, &1)) do
          {0, 0}
        else
          {1, 0}
        end

      _other ->
        {1, 0}
    end
  end

  @spec jobs_match?([PlanJob.t()], [{String.t(), [String.t()], [String.t()]}]) :: boolean()
  defp jobs_match?(plan, expected) do
    actual =
      Enum.map(plan, fn %PlanJob{key: key, needs: needs, runs_on: runs_on} ->
        {key, needs, runs_on}
      end)

    actual == expected
  end
end
