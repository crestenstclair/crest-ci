package crestci

// Gateway — the service the runner dials. Active-active, stateless: session
// identity and job assignment are projections of CRs plus signed tokens; the
// only replica-local state is open connections. Serves the runner protocol
// v0: session create, message long-poll, job acquisition (RunnerJob lease
// CAS), timeline/log ingest, completion.
// Modules live under apps/crest_ci_gateway/lib/crest_ci_gateway/.

project: contexts: Gateway: purpose: "active-active runner gateway: long-poll job delivery, exactly-once acquisition by resourceVersion CAS, idempotent log-chunk ingest, and completion projection into WorkflowRun status"

project: contexts: Gateway: meta: notes: "modules live in apps/crest_ci_gateway/lib/crest_ci_gateway/, tests in apps/crest_ci_gateway/test/. A gateway replica is start_link-able with (kube conn, signing key, port: 0) and reports its bound port; several replicas run side by side in one BEAM during tests."

project: contexts: Gateway: ubiquitousLanguage: {
	Session:   "a runner's authenticated attachment, encoded entirely in a signed token — no server-side session record"
	LongPoll:  "a parked HTTP request answered when a matching job appears or the poll deadline lapses"
	LeaseCAS:  "the compare-and-swap on RunnerJob status that arbitrates which replica delivers a job"
	ChunkSeq:  "the (jobKey, step, sequence) coordinate that makes log uploads idempotent"
}

project: contexts: Gateway: valueObjects: {
	RunnerToken: {from: "string", description: "signed, self-contained bearer token scoping a runner to its one RunnerJob; carries runner name, job name, and expiry", invariants: [
		"verifiable by ANY replica holding the shared signing key — carries everything needed, no lookup",
		"expired or tampered tokens are rejected with 401 before any store access",
	]}
	LogChunk: {state: {jobKey: "JobKey", step: "string", seq: "int", content: "string"}, description: "one uploaded slice of step output"}
}

project: contexts: Gateway: domainServices: {
	LeaseArbiter: {
		purpose: "lease a Queued RunnerJob to a polling runner via status CAS (Queued->Leased with leasedBy + leaseExpiresAt), confirm acquisition on runner ack (Leased->Acquired); a lost CAS returns :lost and the caller re-polls"
		uses: ["port.Contract.KubeClient", "valueObject.Contract.RunnerJobStatus"]
	}
	TokenIssuer: {
		purpose: "mint and verify RunnerTokens with a shared secret; stateless — any replica verifies any replica's tokens"
		uses: ["valueObject.Gateway.RunnerToken"]
	}
	StatusProjector: {
		purpose: "project runner-reported progress into WorkflowRun status.jobs.<key> (Assigned/Running transitions, outputs, completion result) via status CAS with reread-and-retry on conflict"
		uses: ["port.Contract.KubeClient", "valueObject.Contract.JobStatus"]
	}
}

project: contexts: Gateway: applicationServices: {
	JobDispatcher: {
		purpose: "parks long-poll requests by runs-on label set; on RunnerJob watch events (or poll arrival when jobs already wait), attempts LeaseArbiter CAS and answers the winning poll with the job message"
		uses: ["domainService.Gateway.LeaseArbiter", "port.Contract.KubeClient"]
	}
	LogIngest: {
		purpose: "accepts LogChunks, deduplicates by (job, step, seq), appends to the job's log via the BlobStore port, and tracks chunk count for the job status"
		uses: ["valueObject.Gateway.LogChunk", "port.Gateway.BlobStore"]
	}
}

// Storage behind a port: this slice ships a local-filesystem adapter; the S3
// adapter is a later phase and must slot in without touching LogIngest.
project: contexts: Gateway: ports: BlobStore: {
	contract: {
		append_chunk: "(store, run, job, step, seq, content) -> :ok | {:error, term} — idempotent by (run, job, step, seq)"
		read_log:     "(store, run, job) -> {:ok, ordered full text} | {:error, term}"
	}
}

project: adapters: LocalFsBlobStore: {
	implements: "port.Gateway.BlobStore"
	layer:      "infrastructure"
	meta: notes: "chunk files under a configurable root (var/blobs by default); idempotency = chunk path derived from (run, job, step, seq), write-if-absent"
}

project: contexts: Gateway: ports: RunnerProtocolHttp: {
	contract: {
		serve: "(deps, port) -> {:ok, server} — the HTTP surface runners dial"
	}
	meta: notes: "endpoints v0: POST /session (JIT-config auth -> RunnerToken), GET /session/messages (long-poll, deadline ~30s, returns job message or 204), POST /jobs/:name/ack (confirm acquisition), POST /jobs/:name/logs (chunk upload), POST /jobs/:name/timeline (step status), POST /jobs/:name/complete (result + outputs). All job-scoped routes authenticate the RunnerToken and reject cross-job access. Unknown routes return 500 and log loudly (bring-up rule from the design doc)."
}

project: adapters: GatewayHttpServer: {
	implements: "port.Gateway.RunnerProtocolHttp"
	layer:      "infrastructure"
	meta: {
		framework: "plug + bandit"
		notes:     "thin router; long-poll parking lives in JobDispatcher, not in the Plug process"
	}
}

project: contexts: Gateway: invariants: [
	"a RunnerJob is delivered to exactly one runner: the LeaseArbiter CAS is the only path to Leased, and a lost CAS never results in a delivered job message",
	"log ingest is idempotent: replaying any subset of already-ingested chunks changes neither stored content nor chunk counts",
	"a runner that reconnects to a DIFFERENT replica mid-job continues without re-authentication beyond its token — no replica-local lookup may be required",
	"completion is recorded exactly once per job even when the complete call is retried against multiple replicas",
]

// Property proof of the arbitration invariant — the gateway's core claim.
project: assets: AcquisitionPropertyTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_gateway/test/acquisition_property_test.exs — StreamData property: N racing acquirers, exactly one winner, every time"
	uses: ["domainService.Gateway.LeaseArbiter", "adapter.MockK8sHttpServer"]
	prompts: [
		"File path: apps/crest_ci_gateway/test/acquisition_property_test.exs, tagged @tag :property (and included in the default run).",
		"Property (StreamData, at least 50 runs): given a fresh Queued RunnerJob on a live MockK8s server and a generated number of concurrent acquirers (2..20) racing LeaseArbiter across at least two distinct gateway conn identities, exactly one acquirer receives {:ok, leased} and all others receive :lost.",
		"After each property iteration, read the RunnerJob back and assert its status shows exactly the winner's identity in leasedBy.",
		"Accumulate totals across all iterations and print `races=<n> single_winner_violations=<count>` where the count is computed from actual observed winner sets; assert it is 0.",
	]
	validations: [
		{kind: "integration", command: ["make", "props"], description: "acquisition property suite green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "single_winner_violations=0"},
		]},
	]
}
