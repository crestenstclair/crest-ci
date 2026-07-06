package crestci

// SimRunner — a protocol-real runner client: it speaks the gateway's runner
// protocol exactly (session, long-poll, ack, timeline, chunked logs,
// complete) with simulated step execution. It is the in-gate acceptance
// vehicle for this slice; pointing the OFFICIAL actions/runner binary at the
// gateway is a manual, out-of-gate exercise for a later phase.
// Modules live under apps/sim_runner/lib/sim_runner/.

project: contexts: SimRunner: purpose: "protocol-faithful simulated runner: one process per runner walking session -> poll -> acquire -> execute (simulated) -> stream logs -> complete, with reconnect-on-replica-failure behavior"

project: contexts: SimRunner: meta: notes: "modules live in apps/sim_runner/lib/sim_runner/, tests in apps/sim_runner/test/. A runner is start_link-able with (gateway URLs, jit config, step timing opts) and reports its lifecycle to the caller; it takes a LIST of gateway base URLs and fails over to the next on connection loss or 5xx."

project: contexts: SimRunner: aggregates: {
	RunnerClient: {
		root:    true
		purpose: "the runner lifecycle state machine"
		state: {phase: "enum: Connecting, Polling, Executing, Reporting, Done, Failed", jobName: "string", gatewayUrls: "list<string>", currentUrl: "string", chunksSent: "int"}
		commands: [
			{name: "Start", payload: {jitConfig: "map", gatewayUrls: "list<string>"}},
			{name: "ExecuteJob", payload: {jobMessage: "map"}},
		]
		events: [
			{name: "JobAcquired", payload: {jobName: "string"}},
			{name: "JobCompleted", payload: {jobName: "string", result: "string", chunksSent: "int"}},
		]
		invariants: [
			"an ephemeral runner executes exactly one job and then terminates",
			"every log chunk carries a strictly increasing seq per (job, step); on reconnect the runner re-sends the last unacknowledged chunk (relying on server idempotency)",
			"on connection failure or 5xx the runner rotates to the next gateway URL and resumes with the same token — it never restarts the job",
			"job-message steps are executed by kind: run (simulated output), upload_artifact (artifacts create/upload/finalize flow against the gateway), cache_restore and cache_save (cache lookup/reserve-upload-commit flow) — all through the gateway's HTTP APIs with the job-scoped token, and a cache_restore miss never fails the step",
		]
	}
}

// The M2 exit criterion, in-gate: one WorkflowRun with a needs DAG flows
// through controller -> queue -> gateway -> SimRunner -> completion, across a
// gateway replica kill, with measured results printed and asserted in code.
project: assets: E2EDemo: {
	kind:        "elixir-demo"
	description: "mix crest_ci.demo_e2e — boots mock-k8s + 3 controllers + 2 gateway replicas + SimRunners, runs a 3-job DAG to completion through a gateway replica kill, prints measured results"
	uses: ["aggregate.SimRunner.RunnerClient", "applicationService.Controller.RunReconciler", "applicationService.Gateway.JobDispatcher", "applicationService.Gateway.LogIngest", "adapter.GatewayHttpServer", "adapter.MockK8sHttpServer"]
	prompts: [
		"File path: apps/sim_runner/lib/mix/tasks/crest_ci.demo_e2e.ex (a Mix task, runnable from the umbrella root as `mix crest_ci.demo_e2e`), plus any harness module it needs under apps/sim_runner/lib/sim_runner/.",
		"Boot in one BEAM: MockK8s server, THREE controller instances (short election timings), TWO gateway replicas sharing one signing key, and a LocalFsBlobStore rooted in a temp dir. Submit one WorkflowRun with a hand-planned 3-job DAG: build, then test-a and test-b both needing build. Each planned job's message instructs the SimRunner to emit at least 40 log chunks across 3 steps with a few milliseconds between chunks.",
		"Start one SimRunner per created runner pod object (watch for pod objects, then start a RunnerClient with BOTH gateway URLs and the pod's JIT config from its spec).",
		"While test-a and test-b are executing (observed via WorkflowRun status, not a timer), kill one gateway replica's supervisor with Process.exit(:kill); the affected runners must fail over to the surviving replica and finish.",
		"When the run reaches a terminal phase, verify from AUTHORITATIVE state (the store and the blob store, not client-side counters): run phase; per (run, jobKey) exactly one RunnerJob and one pod; total acquisitions vs deliveries; and for every job, reconstruct the log from the BlobStore and check that each step's chunk seqs are exactly 1..max with no gaps and no duplicated content.",
		"Print exactly one summary line: `runs_succeeded=<n> jobs_completed=<n> duplicate_acquisitions=<n> gateway_killed=true log_chunks=<total ingested> gapless=<true|false>` — every value computed from the verification pass. Exit with a non-zero status (raise/Mix.raise) if runs_succeeded != 1, jobs_completed != 3, duplicate_acquisitions != 0, or gapless != true.",
	]
	validations: [
		{kind: "integration", command: ["make", "demo-e2e"], description: "full-stack e2e with gateway kill: 3 jobs complete, zero duplicate acquisitions, gapless logs", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "runs_succeeded=1"},
			{kind: "stdout_contains", pattern: "jobs_completed=3"},
			{kind: "stdout_contains", pattern: "duplicate_acquisitions=0"},
			{kind: "stdout_contains", pattern: "gapless=true"},
		]},
	]
}
