package crestci

// Controller — the leader-elected control plane. Watches WorkflowRuns, turns
// their (hand-planned, this slice) job DAGs into RunnerJobs + runner pod
// objects, sweeps expired leases, and aggregates terminal state. The workflow
// engine (YAML parsing, matrix, reusable workflows) is a LATER phase: here the
// expanded plan arrives pre-built in WorkflowRun spec.plan.
// Modules live under apps/crest_ci_controller/lib/crest_ci_controller/.

project: contexts: Controller: purpose: "leader-elected, level-triggered reconciler: WorkflowRun plans become RunnerJobs and pod objects; needs-gating, lease abandonment sweeping, and terminal aggregation"

project: contexts: Controller: meta: notes: "modules live in apps/crest_ci_controller/lib/crest_ci_controller/, tests in apps/crest_ci_controller/test/. A controller instance is start_link-able with (kube conn, identity, election timings) so tests boot several against one mock server; nothing reads global config."

project: contexts: Controller: ubiquitousLanguage: {
	Leader:      "the one replica whose reconcilers act; holds the coordination Lease"
	WarmStandby: "a non-leader replica keeping caches current so takeover is immediate"
	Runnable:    "a plan job whose needs are all Succeeded and which has no RunnerJob yet"
}

// Pure functional core — trivially unit-testable, no processes.
project: contexts: Controller: domainServices: {
	NeedsResolver: {
		purpose: "pure function: (plan, job statuses) -> the set of runnable job keys, jobs to skip because a dependency failed, and whether the run is terminal with which phase"
		uses: ["valueObject.Contract.PlanJob", "valueObject.Contract.JobStatus", "valueObject.Contract.WorkflowRunPhase"]
	}
	ReconcilePlanner: {
		purpose: "pure function: (workflow_run, existing runner jobs) -> the list of side-effect commands (create RunnerJob X, create pod Y, patch status Z) that would converge the world; the reconciler process just executes them"
		uses: ["domainService.Controller.NeedsResolver", "domainService.Contract.DeterministicNaming", "valueObject.Contract.RunnerJobSpec"]
	}
}

project: contexts: Controller: applicationServices: {
	LeaderElector: {
		purpose: "coordination-Lease-based election: acquire when unheld or expired, renew on an interval, step down cleanly on shutdown; exposes leader?/0 and notifies subscribers on transitions"
		uses: ["port.Contract.KubeClient", "valueObject.Contract.LeaseSpec"]
	}
	RunReconciler: {
		purpose: "watches WorkflowRuns and RunnerJobs (leader only): executes ReconcilePlanner commands — creates RunnerJobs for runnable jobs, creates the runner pod object per RunnerJob, marks skipped jobs, aggregates the run phase when all jobs are terminal"
		uses: ["domainService.Controller.ReconcilePlanner", "port.Contract.KubeClient"]
	}
	LeaseSweeper: {
		purpose: "periodically scans RunnerJobs: Leased past leaseExpiresAt without acquisition -> back to Queued (re-deliverable); Acquired whose lease heartbeat lapsed -> Abandoned and the owning job marked Failed"
		uses: ["port.Contract.KubeClient", "valueObject.Contract.RunnerJobStatus"]
	}
}

project: contexts: Controller: invariants: [
	"only the leader's reconcilers execute side effects; standbys watch but never write",
	"every write the reconciler performs is derived from ReconcilePlanner output — no ad-hoc mutations from process callbacks",
	"a reconcile pass that crashes or is killed midway leaves the world in a state the next pass converges from (partial child creation is repaired by 409-tolerant re-creates)",
	"the run phase is Succeeded only when every plan job is Succeeded or Skipped; Failed as soon as any job is Failed and no retry applies; phase writes use status CAS",
]

// The G1 proof for this slice: leadership fails over fast, and failover never
// duplicates children.
project: assets: FailoverChaosTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_controller/test/failover_chaos_test.exs — kill the leader mid-flight, measure takeover, prove zero duplicate children"
	uses: ["applicationService.Controller.LeaderElector", "applicationService.Controller.RunReconciler", "adapter.MockK8sHttpServer"]
	prompts: [
		"File path: apps/crest_ci_controller/test/failover_chaos_test.exs, tagged @tag :chaos (and included in the default run — do not exclude it in test_helper).",
		"Boot one MockK8s server and THREE controller instances with short election timings (lease duration ~2s, renew ~500ms). Submit 10 WorkflowRuns whose hand-planned DAGs total at least 30 jobs. While RunnerJobs are still being created, brutally kill the current leader (Process.exit(pid, :kill) on its supervisor).",
		"Externally satisfy RunnerJobs so runs can finish: the test completes each RunnerJob through the Kubernetes API the way a gateway would (status CAS to Completed + job status patch) — no gateway app dependency in this suite.",
		"Wait on observable state (poll the API), never on timers. Measure the leadership gap: time from killing the leader to another instance's Lease acquireTime. Print `failover_gap_ms=<measured integer>` and assert it is under 10000.",
		"After all runs reach a terminal phase, list ALL RunnerJobs and pods and assert exactly one child per (run, jobKey) — print `duplicate_children=<count>` computed from the actual listing and assert it equals 0.",
		"Also assert every one of the 10 runs reached Succeeded, and print `runs_succeeded=<count>`.",
	]
	validations: [
		{kind: "integration", command: ["make", "chaos"], description: "leader-failover chaos suite green with zero duplicates", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "duplicate_children=0"},
			{kind: "stdout_contains", pattern: "runs_succeeded=10"},
		]},
	]
}
