package crestci

// Engine — the workflow engine's C1 tier (D2 §5): parse real GitHub Actions
// workflow YAML, evaluate the SERVER-side expression scope, assemble contexts,
// and produce the expanded PlanJob DAG that until now arrived hand-planned in
// WorkflowRun spec.plan. C1 scope: `run` steps, `needs`, job-level `if`,
// workflow/job `env`, `runs-on`. Matrix, reusable workflows, and concurrency
// are the C2 tier (a later phase). Fully deterministic pure library — same
// inputs always produce a byte-identical plan.
// Modules live under apps/crest_ci_controller/lib/crest_ci_controller/engine/.

project: contexts: Engine: purpose: "deterministic workflow engine, C1 tier: YAML workflow parsing, server-side expression evaluation, context assembly, and needs-DAG planning — plan(definition, event, context) -> PlanJob list or a structured error"

project: contexts: Engine: meta: notes: "modules live in apps/crest_ci_controller/lib/crest_ci_controller/engine/, tests in apps/crest_ci_controller/test/engine/. Pure functions only — no processes, no clock reads (timestamps arrive as inputs). Step-level expressions ship UNEVALUATED to the runner (GitHub's own split); the server-side scope is workflow/job level only: job if, job env merge, runs-on, needs references."

project: contexts: Engine: ubiquitousLanguage: {
	Definition: "a parsed workflow file: triggers, env, defaults, and jobs with steps"
	ServerScope: "the expression surface evaluated engine-side: job if / env / runs-on / needs.*"
	PlanError:  "a structured, human-readable rejection: unknown needs target, dependency cycle, invalid YAML"
}

project: contexts: Engine: valueObjects: {
	WorkflowDefinition: {
		state: {name: "string", on: "map", env: "map<string,string>", jobs: "map<string,JobDefinition>", rawYaml: "string"}
		description: "parsed IR of one workflow file; unknown keys are retained as warnings, never errors (GitHub tolerates; we match)"
	}
	JobDefinition: {
		state: {id: "string", name: "string", needs: "list<string>", runsOn: "list<string>", condition: "string", env: "map<string,string>", steps: "list<map>", timeoutMinutes: "int"}
		description: "one job as declared: steps stay in template form (unevaluated ${{ }} inside steps)"
	}
	ExprValue: {
		from: "enum", description: "an evaluated expression result: Null, Bool, Number, String — with GitHub's truthiness and loose-equality coercion rules"
	}
	GithubContext: {
		state: {event: "map", eventName: "string", ref: "string", sha: "string", repository: "string", actor: "string"}
		description: "the github.* context assembled from the trigger event"
	}
}

project: contexts: Engine: domainServices: {
	WorkflowParser: {
		purpose: "pure: (yaml string) -> {:ok, WorkflowDefinition, warnings} | {:error, PlanError}; honors YAML anchors/merge keys; unknown top-level or job keys become warnings carrying the key path"
		uses: ["valueObject.Engine.WorkflowDefinition", "valueObject.Engine.JobDefinition"]
	}
	ExpressionEvaluator: {
		purpose: "pure: evaluate one ${{ }} expression against a context map — literals; == != < <= > >= && || ! ; index/property access; functions contains, startsWith, endsWith, format, join, toJSON, fromJSON, always, success, failure, cancelled — with GitHub's coercion semantics (loose equality, string-number comparison, null/empty falsiness)"
		uses: ["valueObject.Engine.ExprValue"]
	}
	ContextAssembler: {
		purpose: "pure: build the per-job evaluation context: github (from GithubContext), needs (results + outputs of satisfied dependencies), env (workflow -> job merge, job wins); step-level merging is explicitly NOT done here (runner-side)"
		uses: ["valueObject.Engine.GithubContext", "valueObject.Contract.JobStatus"]
	}
	Planner: {
		purpose: "pure: plan(WorkflowDefinition, GithubContext) -> {:ok, [PlanJob]} | {:error, PlanError}: validates the needs DAG (unknown targets and cycles are structured errors naming the offending jobs), evaluates job-level if conditions against the assembled context (a false condition marks the job skipped-at-plan-time by exclusion), interpolates runs-on and job env, and emits PlanJobs in a deterministic stable order (topological, ties broken lexicographically)"
		uses: ["domainService.Engine.WorkflowParser", "domainService.Engine.ExpressionEvaluator", "domainService.Engine.ContextAssembler", "valueObject.Contract.PlanJob"]
	}
	JobMessageRenderer: {
		purpose: "pure: render_job_message(PlanJob, contexts) -> the job message map the gateway serves: steps in template form (unevaluated), evaluated env, needs outputs snapshot — deterministic, same inputs byte-identical output"
		uses: ["domainService.Engine.ContextAssembler", "valueObject.Contract.PlanJob"]
	}
}

project: contexts: Engine: invariants: [
	"the engine is deterministic: identical (definition, event, context) inputs produce byte-identical plans and job messages — no clock reads, no randomness, no environment access",
	"step-level expressions are never evaluated server-side — they ship to the runner in template form",
	"a needs reference to an unknown job or a dependency cycle is a structured PlanError naming the offending job ids, never a crash or a silent drop",
	"plan output order is stable: topological over needs with lexicographic tie-breaking",
	"expression coercion matches GitHub semantics: loose equality across types, null/empty-string/zero falsiness, string comparison of mixed operands per the documented rules",
]

// Integrates the engine into the controller: WorkflowRuns may now carry a
// workflow YAML instead of a hand-built plan.
project: contexts: Controller: applicationServices: PlanFromDefinition: {
	purpose: "when a WorkflowRun's spec carries workflowYaml (and no hand-built plan), run the Engine Planner at first reconcile and write the resulting plan into the run's status before job creation; PlanErrors mark the run Failed with the structured error recorded — hand-planned runs continue to work unchanged"
	uses: ["domainService.Engine.Planner", "port.Contract.KubeClient", "applicationService.Controller.RunReconciler"]
}

// ── Proof assets ──────────────────────────────────────────────────────────────

project: assets: ExpressionConformanceTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_controller/test/engine/expression_conformance_test.exs — table-driven evaluator vectors covering GitHub coercion semantics"
	uses: ["domainService.Engine.ExpressionEvaluator"]
	prompts: [
		"File path: apps/crest_ci_controller/test/engine/expression_conformance_test.exs.",
		"Table-driven: at least 60 vectors as {expression, context, expected} tuples covering: literals (null/bool/number/string incl. hex and exponent), every operator, property + index access (missing property -> null, never raise), each function (contains on strings AND arrays, format with escaped braces, join with custom separator, toJSON/fromJSON round-trip), GitHub coercion edge cases (null == '', '1' == 1, true == 1, string comparison case-insensitivity per docs), and always/success/failure/cancelled against a job-status context.",
		"Count and print exactly one line: `vectors=<n> failures=<n>` where failures counts vectors whose evaluated result mismatched expected; the suite asserts failures == 0 and vectors >= 60.",
	]
	validations: [
		{kind: "integration", command: ["make", "engine"], description: "expression vectors green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "failures=0"},
		]},
	]
}

project: assets: PlannerGoldenTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_controller/test/engine/planner_golden_test.exs — real workflow YAML fixtures through parse+plan with golden expectations"
	uses: ["domainService.Engine.Planner", "domainService.Engine.WorkflowParser"]
	prompts: [
		"File path: apps/crest_ci_controller/test/engine/planner_golden_test.exs, with YAML fixtures under apps/crest_ci_controller/test/engine/fixtures/.",
		"Fixtures (realistic GitHub Actions syntax): (1) a build->test->deploy chain with needs and a job-level if referencing github.ref; (2) a workflow using YAML anchors and workflow+job env merging; (3) a fan-out/fan-in diamond (four jobs); (4) an unknown-needs-target workflow; (5) a cyclic-needs workflow; (6) a workflow with unknown keys that must plan successfully with warnings.",
		"Assert per fixture: exact PlanJob keys/needs/runsOn/order for 1-3 (stable across two plan calls — assert byte-identical encoded plans); structured PlanError naming the offending jobs for 4-5; warnings non-empty but plan ok for 6.",
		"Print exactly one line: `fixtures=<n> plan_mismatches=<n> determinism_violations=<n>` from measured comparisons; assert both counts are 0.",
	]
	validations: [
		{kind: "integration", command: ["make", "engine"], description: "planner golden fixtures green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "plan_mismatches=0"},
			{kind: "stdout_contains", pattern: "determinism_violations=0"},
		]},
	]
}

project: assets: EngineE2EDemo: {
	kind:        "elixir-demo"
	description: "mix crest_ci.demo_engine — a real workflow YAML drives the full stack end-to-end: parse, plan, execute, verify"
	uses: ["applicationService.Controller.PlanFromDefinition", "domainService.Engine.Planner", "aggregate.SimRunner.RunnerClient", "asset.E2EDemo"]
	prompts: [
		"File path: apps/sim_runner/lib/mix/tasks/crest_ci.demo_engine.ex (runnable as `mix crest_ci.demo_engine`), reusing the existing e2e harness modules.",
		"Boot the full in-BEAM stack. Submit a WorkflowRun whose spec carries workflowYaml (NO hand-built plan): a realistic 4-job workflow (lint and build in parallel; test needs build; package needs [lint, test]; test has a job-level if referencing github.ref that evaluates TRUE for the submitted event). Include one job whose if evaluates FALSE for the event — it must be absent from the plan.",
		"Drive to completion with SimRunners. Verify from authoritative state: the planned DAG matches the YAML's structure (assert the exact needs edges), the false-if job never ran, all planned jobs Succeeded, and re-planning the same YAML+event in-process yields a byte-identical plan.",
		"Print exactly one line: `planned_jobs=<n> excluded_by_if=<n> runs_succeeded=<n> plan_deterministic=<true|false>` and exit non-zero unless planned_jobs=4, excluded_by_if=1, runs_succeeded=1, plan_deterministic=true.",
	]
	validations: [
		{kind: "integration", command: ["make", "demo-engine"], description: "engine-planned workflow end-to-end", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "planned_jobs=4"},
			{kind: "stdout_contains", pattern: "excluded_by_if=1"},
			{kind: "stdout_contains", pattern: "runs_succeeded=1"},
			{kind: "stdout_contains", pattern: "plan_deterministic=true"},
		]},
	]
}
