package crestci

// Scene — the watchable demo: `make demo-scene` boots the full in-BEAM stack
// and puts on a narrated, timed show with a live ANSI dashboard. The dashboard
// is an HONEST OBSERVER: it reads only authoritative CR state through the
// Kubernetes API (the same contract a real dashboard would use) — never
// process internals. The scene doubles as an acceptance artifact: it ends
// with a measured scoreboard and a non-zero exit on any invariant violation.
// Modules live under apps/sim_runner/lib/sim_runner/scene/.

project: contexts: Scene: purpose: "live demo theater: a scenario director submitting real workflow YAML on a trickle, a scripted chaos director killing leaders and gateways on a timeline, and a TTY dashboard rendering authoritative cluster state a few times per second, ending in a measured scoreboard"

project: contexts: Scene: meta: notes: "modules live in apps/sim_runner/lib/sim_runner/scene/, tests in apps/sim_runner/test/scene/. The renderer must degrade gracefully: when stdout is not a TTY (or NO_COLOR/DEMO_HEADLESS is set) it emits plain append-only narration lines instead of ANSI cursor-home redraws, so the scene runs identically under the validation gate and CI."

project: contexts: Scene: ubiquitousLanguage: {
	Snapshot:   "one observation of the world, assembled purely from CRs: runs with per-job phases, queue depths, leader identity, acquisition/chunk counters"
	SceneEvent: "one timeline entry: at elapsed ms, do a thing (kill-leader, kill-gateway, burst, submit) and narrate it"
	Scoreboard: "the final measured verdict: runs succeeded, duplicate acquisitions, failover gaps, gapless archives"
}

project: contexts: Scene: valueObjects: {
	SceneEvent: {
		state: {atMs: "int", kind: "enum: KillLeader, KillGateway, Burst, Submit, Narrate", detail: "map"}
		description: "a scripted timeline entry; the default timeline kills the controller leader ~t+20s, a gateway replica ~t+35s, and fires a run burst ~t+60s"
	}
	Snapshot: {
		state: {elapsedMs: "int", leader: "string", leaseRemainingS: "int", gateways: "list<map>", queued: "int", leased: "int", running: "int", done: "int", runs: "list<map>", acquisitions: "int", duplicateAcquisitions: "int", chunkCount: "int", cacheHits: "int", cacheMisses: "int", failovers: "list<map>"}
		description: "dashboard model derived ONLY from CRs (WorkflowRuns, RunnerJobs, Lease, pods) and job outputs; duplicate acquisitions computed from RunnerJob status history, cache hits/misses from the cache-step outputs jobs record"
	}
	Scoreboard: {
		state: {runsSucceeded: "int", runsFailed: "int", duplicateAcquisitions: "int", controllerFailovers: "int", controllerFailoverGapMs: "int", gatewayFailovers: "int", rehomedRunners: "int", archiveGaps: "int", cacheHits: "int"}
		description: "final verdict, every field computed from authoritative state in a verification pass identical in spirit to the existing demos'"
	}
}

project: contexts: Scene: domainServices: {
	StateSnapshotter: {
		purpose: "pure given fetched inputs: assemble a Snapshot from listed CRs (runs, runner jobs, leases, pods) — the single source the renderer sees; no side channels into director or process state"
		uses: ["port.Contract.KubeClient", "valueObject.Scene.Snapshot"]
	}
	TtyRenderer: {
		purpose: "pure: (Snapshot, recent narration lines, elapsed, duration) -> one frame string. TTY mode: fixed-layout ANSI frame (cursor-home redraw, run progress bars, phase glyphs, counters, last ~6 narration lines). Headless mode: only NEW narration/state-change lines, append-only"
		uses: ["valueObject.Scene.Snapshot"]
	}
	ChaosTimeline: {
		purpose: "pure: (timeline, elapsedMs, alreadyFired) -> due SceneEvents; the default timeline is deterministic and encoded as data so tests can inject compressed timelines"
		uses: ["valueObject.Scene.SceneEvent"]
	}
}

project: contexts: Scene: applicationServices: {
	ScenarioDirector: {
		purpose: "submits WorkflowRuns built from the scene workflow library (real YAML files under apps/sim_runner/priv/scene_workflows/) on a steady trickle; workflows carry workflowYaml so the engine plans them live; starts SimRunners for created pods exactly as the existing e2e harness does"
		uses: ["applicationService.Controller.PlanFromDefinition", "aggregate.SimRunner.RunnerClient", "port.Contract.KubeClient"]
	}
	ChaosDirector: {
		purpose: "executes due SceneEvents: KillLeader brutally kills the current leader's supervisor and measures the gap to the next Lease acquisition; KillGateway kills one gateway replica and counts re-homed runners; Burst submits N runs at once — each event emits a narration banner with the measured before/after"
		uses: ["domainService.Scene.ChaosTimeline", "port.Contract.KubeClient"]
	}
	SceneRunner: {
		purpose: "the conductor: boots mock-k8s + 3 controllers + 2 gateways + stores in temp dirs, starts directors, ticks the snapshot->render loop ~4x/s (1x/s headless), stops at DEMO_DURATION (default 90s; DEMO_FOREVER=1 runs until interrupt), then runs the verification pass, prints the Scoreboard as one parseable line plus a human table, and exits non-zero if runsFailed > 0, duplicateAcquisitions > 0, archiveGaps > 0, or no controller failover was observed when the timeline scheduled one"
		uses: ["domainService.Scene.StateSnapshotter", "domainService.Scene.TtyRenderer", "applicationService.Scene.ScenarioDirector", "applicationService.Scene.ChaosDirector", "valueObject.Scene.Scoreboard"]
	}
}

project: contexts: Scene: invariants: [
	"the dashboard reads only CR state via the Kubernetes API and job-recorded outputs — never director bookkeeping or process introspection; killing the dashboard changes nothing about the run",
	"the scene is deterministic in structure: the same timeline fires the same events at the same offsets; only workload timing varies",
	"chaos events never touch the mock-k8s store process — they kill controllers and gateways only, because the store stands in for etcd which is out of scope for chaos",
	"headless mode produces the same scoreboard as TTY mode — rendering is presentation only",
]

project: assets: DemoScene: {
	kind:        "elixir-demo"
	description: "mix crest_ci.demo_scene + make demo-scene — the live narrated demo with ANSI dashboard, scripted chaos, and a measured exit scoreboard"
	uses: ["applicationService.Scene.SceneRunner", "asset.EngineE2EDemo"]
	prompts: [
		"Files: apps/sim_runner/lib/mix/tasks/crest_ci.demo_scene.ex (runnable as `mix crest_ci.demo_scene` from the umbrella root), plus the scene workflow library under apps/sim_runner/priv/scene_workflows/ — at least four REAL GitHub Actions YAML files: a build->test chain, a four-job diamond, one with a job-level if that evaluates false for the submitted event, and one whose steps exercise upload_artifact + cache_restore/cache_save.",
		"Honor env vars: DEMO_DURATION (seconds, default 90), DEMO_FOREVER=1 (run until Ctrl-C; scoreboard on interrupt), DEMO_HEADLESS=1 (force append-only narration). Auto-detect non-TTY stdout as headless.",
		"The default timeline: t+20s KillLeader, t+35s KillGateway, t+60s Burst of 15 runs. Scale offsets proportionally when DEMO_DURATION is shorter than 90s so a 25s headless run still exercises all three events.",
		"The final output MUST include exactly one machine-parseable line: `scoreboard runs_succeeded=<n> runs_failed=<n> duplicate_acquisitions=<n> controller_failovers=<n> failover_gap_ms=<n> gateway_failovers=<n> rehomed_runners=<n> archive_gaps=<n> cache_hits=<n>` — every value from the verification pass, never from director counters. Exit non-zero per SceneRunner's invariant rules.",
		"OUTPUT DELIVERY IS PART OF THE CONTRACT: the scoreboard line must reach a PIPED stdout before the OS process exits, in every mode. Print it with IO.puts to :stdio and never exit via System.halt (which drops unflushed IO) — let the Mix task return normally, or use System.stop with a flush. KNOWN REGRESSION TO FIX: `make demo-scene-check > log 2>&1` currently exits 0 with NO scoreboard line in the captured log (warnings only) — reproduce that exact invocation, find where the final print is lost (halt-before-flush, output written to a dead renderer device, or the verification pass never running), fix it, and prove the fix by grepping the captured file, not the terminal.",
	]
	validations: [
		{kind: "integration", command: ["make", "demo-scene-check"], description: "25s headless scene: all chaos events fire, zero invariant violations", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "duplicate_acquisitions=0"},
			{kind: "stdout_contains", pattern: "controller_failovers=1"},
			{kind: "stdout_contains", pattern: "gateway_failovers=1"},
			{kind: "stdout_contains", pattern: "archive_gaps=0"},
			{kind: "stdout_contains", pattern: "runs_failed=0"},
		]},
	]
}
