package crestci

// crest-ci — a self-hosted, high-availability replacement for the GitHub
// Actions SERVICE. The central bet: we do not reimplement job execution; we
// reimplement the service the official runner talks to. This spec covers the
// M0–M2 slice: contract package + CRD structs, an in-memory mock Kubernetes
// API server, the leader-elected controller skeleton (run reconciler +
// RunnerJob lease queue), gateway v0 (runner protocol + log ingest), and a
// protocol-real simulated runner that proves one job end-to-end through the
// whole stack. Full design: docs/DESIGN-D2.md (Draft 2 spec).

project: name: "crest-ci"

// Injected into every generator's system prompt.
project: mission: "A high-availability, fully Actions-compatible CI control plane built as an Elixir umbrella. All authoritative state lives in Kubernetes custom resources (etcd is the only database); the controller is leader-elected and level-triggered; the gateway is active-active and stateless — any replica serves any runner at any moment, because session and lease truth are projections of CRs arbitrated by resourceVersion compare-and-swap. Runners dial OUTBOUND to the gateway over long-poll HTTP. This slice runs everything in-BEAM against an in-repo mock Kubernetes API server so the whole system boots, fails over, and completes jobs inside `mix test` on a laptop — no Docker, no k3d, no real runner binary (those are manual targets outside the gate)."

project: layers: ["domain", "application", "infrastructure"]
project: layerRules: {
	application: {dependsOn: ["domain"]}
	infrastructure: {dependsOn: ["domain", "application"]}
}

project: meta: {
	language: "elixir"
	style:    "idiomatic Elixir 1.20 / OTP 29; umbrella project under apps/; pattern matching over conditionals; pure functional cores with OTP processes only at the edges (supervisors, servers, connection handling); tagged tuples {:ok, _} | {:error, _}; @moduledoc and @spec on public modules"
	avoid: [
		"shared mutable state outside Kubernetes custom resources — no ETS/Agent as a source of truth for anything a component pair must agree on",
		"direct function calls or message passing between controller and gateway apps — they communicate only through the Kubernetes API",
		"GenServer state that cannot be reconstructed from CRs after a crash",
		"Process.sleep in production code paths — use monitors, timeouts, and receive deadlines",
		"time-based test synchronization (sleep-and-hope) — tests wait on observable state transitions",
	]
}

// Whole-tree gate: runs across the entire umbrella at wave verification.
// Formatting is NORMALIZED, never policed: `mix format` auto-fixes and always
// passes. The gate blocks on design-level failures only.
project: validations: [
	{kind: "custom", command: ["mix", "format"], description: "normalize formatting (auto-fix, never blocks)"},
	{kind: "custom", command: ["mix", "deps.get"], description: "dependencies fetched"},
	{kind: "compiles", command: ["mix", "compile", "--warnings-as-errors"], description: "umbrella compiles warning-clean"},
	{kind: "test", command: ["mix", "test"], description: "all app test suites pass"},
]

// Architectural invariants — behavioral rules, injected into every generator
// prompt. Code that violates one is wrong even if it compiles and tests pass.
project: invariants: core: [
	// State discipline
	{text: "the Kubernetes API is the only interface between controller and gateway — all coordination happens through custom resources", meta: rationale: "components are independently killable and restartable only if no truth lives in process memory or side channels"},
	{text: "every component can be killed at any moment and the system converges after restart — authoritative state lives only in the resource store", meta: rationale: "G3 statelessness; this is what makes HA failover safe"},
	{text: "status updates go through the status subresource with optimistic concurrency; a stale resourceVersion write is rejected and retried against fresh state, never forced", meta: rationale: "multi-writer discipline between controller and gateway replicas"},

	// Reconciliation
	{text: "reconciliation is level-triggered and idempotent — replaying any event sequence in any order converges to the same state", meta: rationale: "watch streams drop, duplicate, and reorder; correctness cannot depend on edge-triggered delivery"},
	{text: "child resources use deterministic names derived from their parent (run ULID + job key); a 409 AlreadyExists on create is treated as success", meta: rationale: "failover re-reconciles must produce no-ops, never duplicates"},

	// Queue arbitration
	{text: "a RunnerJob is acquired by exactly one runner, ever — arbitration is resourceVersion compare-and-swap on the RunnerJob status; a lost CAS means another actor won and the loser moves on", meta: rationale: "active-active gateway replicas race for the same queue element; CAS on etcd-semantics storage is the only arbiter"},
	{text: "an expired lease (leaseExpiresAt in the past without acquisition heartbeat) transitions the RunnerJob to Abandoned via the controller sweeper, never silently back to Queued by the gateway", meta: rationale: "one owner per state transition keeps the phase machine auditable"},

	// Log ingest
	{text: "log chunk ingestion is idempotent by (job, step, chunk sequence) — re-sending a chunk after reconnect changes nothing", meta: rationale: "runners retry uploads across gateway replica failures; duplicates must be absorbed, not appended"},

	// Gateway statelessness
	{text: "gateway replica-local state is limited to open connections — session identity and job assignment are re-derivable from custom resources plus stateless signed tokens on every request", meta: rationale: "a runner reconnecting to a different replica must be indistinguishable from staying on the same one"},

	// Leadership
	{text: "at most one controller replica reconciles at a time, guarded by a coordination Lease; non-leaders keep warm caches and take over within the configured lease duration plus renew margin", meta: rationale: "split-brain reconciliation would double-create children; warm standby keeps failover under the 20s budget"},
]

// Bounded-context relationships.
project: contextMap: [
	{from: "Contract", to: "MockK8s", kind: "shared-kernel"},
	{from: "Contract", to: "Controller", kind: "shared-kernel"},
	{from: "Contract", to: "Gateway", kind: "shared-kernel"},
	{from: "Contract", to: "SimRunner", kind: "shared-kernel"},
	{from: "MockK8s", to: "Controller", kind: "customer-supplier", direction: "upstream"},
	{from: "MockK8s", to: "Gateway", kind: "customer-supplier", direction: "upstream"},
	{from: "Gateway", to: "SimRunner", kind: "customer-supplier", direction: "upstream"},
	{from: "Controller", to: "Gateway", kind: "anti-corruption", direction: "downstream"},
]

project: assetKinds: {
	"mix-manifest": {description: "a mix.exs manifest or config file for the umbrella or one of its apps", filePattern: "**/mix.exs"}
	"makefile": {description: "the project Makefile — the human entry points", filePattern: "Makefile"}
	"elixir-test-suite": {description: "an ExUnit test suite proving a cross-component behavior", filePattern: "apps/*/test/**/*_test.exs"}
	"elixir-demo": {description: "a runnable demo entry point (mix task) that boots the system and prints measured results", filePattern: "apps/*/lib/mix/tasks/*.ex"}
	"doc": {description: "a project documentation file", filePattern: "docs/*.md"}
}
