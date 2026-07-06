package crestci

// Results — the Results-compatible services from D2 §7, M3 slice: log archive
// compaction, artifacts v4 flow, cache with restore-key semantics, and the
// action tarball proxy shape. ALL storage sits behind ports; this slice ships
// local-filesystem adapters only (S3 adapters are a later phase and must slot
// in without touching the services). Modules live under
// apps/crest_ci_gateway/lib/crest_ci_gateway/results/, tests under
// apps/crest_ci_gateway/test/results/.

project: contexts: Results: purpose: "Results-compatible services behind the gateway: per-job log archives compacted from live chunks, the artifacts v4 create/upload/finalize flow, a cache API with GitHub restore-key and scope semantics, and a fetch-once content-addressed action tarball proxy"

project: contexts: Results: meta: notes: "modules live in apps/crest_ci_gateway/lib/crest_ci_gateway/results/, tests in apps/crest_ci_gateway/test/results/. HTTP surfaces mount into the existing gateway router; job-scoped RunnerTokens authenticate every runner-facing route. Digests use :crypto (sha256); no new external deps."

project: contexts: Results: ubiquitousLanguage: {
	Archive:    "the immutable, ordered, compacted log of one finished job — replaces its live chunks"
	Artifact:   "a named blob set a job uploads: created, uploaded in parts, then finalized atomically"
	RestoreKey: "a cache key prefix fallback: exact key wins, then longest-prefix most-recent"
	Scope:      "the (repo, ref) chain a cache entry is visible in — branch, then default branch"
}

project: contexts: Results: valueObjects: {
	ArtifactName: {from: "string", description: "artifact name as given by the workflow", invariants: [
		"non-empty, no path separators or traversal sequences — it becomes a storage path segment",
	]}
	ArtifactRecord: {
		state: {name: "ArtifactName", runRef: "string", jobKey: "JobKey", sizeBytes: "int", digest: "string", finalizedAt: "string"}
		description: "a finalized artifact's metadata"
	}
	CacheKey: {from: "string", description: "exact cache key, e.g. deps-otp27-a1b2c3", invariants: ["non-empty; comparison is case-sensitive"]}
	CacheScope: {state: {repo: "string", ref: "string"}, description: "visibility scope; lookup walks ref then the default branch ref"}
	CacheEntry: {
		state: {key: "CacheKey", version: "string", scope: "CacheScope", sizeBytes: "int", createdAt: "string", lastUsedAt: "string", state: "enum: Reserved, Committed"}
		description: "one stored cache blob's metadata; only Committed entries are servable"
	}
	LogArchive: {
		state: {runRef: "string", jobKey: "JobKey", lineCount: "int", byteSize: "int"}
		description: "metadata of a compacted per-job log"
	}
}

project: contexts: Results: domainServices: {
	RestoreKeyResolver: {
		purpose: "pure function: (key, restore_keys, scope chain, committed entries) -> the entry to serve or :miss, matching GitHub semantics: exact key in the nearest scope wins; otherwise the longest restore-key prefix match, most recent first; entries from scopes not in the chain are invisible"
		uses: ["valueObject.Results.CacheKey", "valueObject.Results.CacheScope", "valueObject.Results.CacheEntry"]
	}
	LogCompactor: {
		purpose: "pure planning + idempotent execution: given a job's ingested chunks, produce the ordered archive content (every (step, seq) exactly once, seq order within step) and the deletion list for live chunks; compacting an already-archived job is a no-op"
		uses: ["port.Gateway.BlobStore", "valueObject.Results.LogArchive"]
	}
	LruEvictor: {
		purpose: "pure function: (committed entries, byte budget) -> the eviction list, oldest lastUsedAt first, never evicting Reserved entries; result respects the budget with minimal evictions"
		uses: ["valueObject.Results.CacheEntry"]
	}
}

// Storage ports — local-fs adapters in this slice, S3 later.
project: contexts: Results: ports: ArtifactStore: {
	contract: {
		create:      "(store, run, job, name, declared_size) -> {:ok, upload_ref} | {:error, :already_exists | term}"
		upload_part: "(store, upload_ref, part_index, content) -> :ok | {:error, term} — idempotent by (upload_ref, part_index)"
		finalize:    "(store, upload_ref, declared_digest) -> {:ok, ArtifactRecord} | {:error, :digest_mismatch | :size_mismatch | term}"
		list:        "(store, run) -> {:ok, [ArtifactRecord]} — finalized artifacts only"
		read:        "(store, run, name) -> {:ok, binary} | {:error, :not_found}"
	}
	meta: notes: "finalize is the atomic commit point: it verifies size + sha256 digest across the assembled parts and only then makes the artifact visible to list/read; a failed finalize leaves nothing visible"
}

project: contexts: Results: ports: CacheStore: {
	contract: {
		reserve: "(store, key, version, scope) -> {:ok, reservation} | {:error, :already_committed}"
		upload:  "(store, reservation, offset, content) -> :ok — idempotent by (reservation, offset)"
		commit:  "(store, reservation, declared_size) -> {:ok, CacheEntry} | {:error, :size_mismatch}"
		lookup:  "(store, key, restore_keys, scope_chain) -> {:ok, CacheEntry, binary} | :miss — delegates match choice to RestoreKeyResolver and touches lastUsedAt"
		evict:   "(store, byte_budget) -> {:ok, [evicted CacheEntry]} — delegates choice to LruEvictor"
	}
}

project: contexts: Results: ports: ActionProxy: {
	contract: {
		resolve: "(proxy, repo, ref) -> {:ok, tarball_path} | {:error, term} — fetch-once, content-addressed by (repo, resolved ref); concurrent resolves of the same action fetch exactly once"
	}
	meta: notes: "the fetcher is injected (a fun or module): tests and this slice use a local fixture-directory fetcher; the codeload.github.com fetcher is a later phase. Cache hits never invoke the fetcher."
}

project: adapters: LocalFsArtifactStore: {
	implements: "port.Results.ArtifactStore"
	layer:      "infrastructure"
	meta: notes: "parts under <root>/staging/<upload_ref>/<part_index>; finalize assembles, verifies, and renames into <root>/artifacts/<run>/<name> — visibility via atomic rename, never partial files"
}
project: adapters: LocalFsCacheStore: {
	implements: "port.Results.CacheStore"
	layer:      "infrastructure"
	meta: notes: "blobs under <root>/cache/; metadata index persisted as JSON alongside (reloadable after restart); lastUsedAt touched on lookup hits"
}
project: adapters: LocalFsActionCache: {
	implements: "port.Results.ActionProxy"
	layer:      "infrastructure"
	meta: notes: "content-addressed paths <root>/actions/<repo-slug>/<resolved-ref>.tgz; single-flight de-duplication for concurrent resolves of the same key"
}

project: contexts: Results: applicationServices: {
	ArtifactsApi: {
		purpose: "runner-facing HTTP surface for the artifacts flow mounted in the gateway router: create -> upload parts -> finalize; list + download; every route authenticates the job-scoped RunnerToken and is confined to that job's run"
		uses: ["port.Results.ArtifactStore", "domainService.Gateway.TokenIssuer"]
	}
	CacheApi: {
		purpose: "runner-facing HTTP surface for the cache flow: reserve/upload/commit and lookup with key + restore keys + scope chain; misses return a soft miss response, never an error status that fails a job"
		uses: ["port.Results.CacheStore", "domainService.Results.RestoreKeyResolver", "domainService.Gateway.TokenIssuer"]
	}
	ArchiveOnComplete: {
		purpose: "subscribes to job completion (the gateway's completion path): runs LogCompactor, records the LogArchive pointer in the job's status via StatusProjector, deletes live chunks; safe to re-run"
		uses: ["domainService.Results.LogCompactor", "domainService.Gateway.StatusProjector"]
	}
}

project: contexts: Results: invariants: [
	"an artifact is visible to list/read only after a successful finalize — partial or unfinalized uploads never appear anywhere",
	"finalize verifies declared size and sha256 digest against the assembled bytes; any mismatch rejects the artifact and leaves nothing visible",
	"cache lookup matches GitHub semantics: exact key in the nearest scope, else longest restore-key prefix most-recent; entries outside the scope chain are never served",
	"cache misses are soft: a miss is a normal response the job proceeds past, never a failure",
	"a job's archive contains every ingested (step, seq) chunk exactly once, in order; compaction is idempotent and duplicate chunk re-ingests never appear twice",
	"Reserved cache entries are never evicted; eviction is strictly LRU by lastUsedAt within the byte budget",
	"the action proxy fetches a given (repo, resolved ref) at most once ever — concurrent first resolves single-flight into one fetch",
]

// ── Proof assets ──────────────────────────────────────────────────────────────

project: assets: ArtifactsRoundtripTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_gateway/test/results/artifacts_roundtrip_test.exs — full HTTP round-trip with out-of-order and duplicated parts"
	uses: ["applicationService.Results.ArtifactsApi", "adapter.LocalFsArtifactStore", "adapter.GatewayHttpServer"]
	prompts: [
		"File path: apps/crest_ci_gateway/test/results/artifacts_roundtrip_test.exs.",
		"Boot a gateway replica on an ephemeral port with a LocalFsArtifactStore in a temp dir. Over REAL HTTP with a job-scoped token: create an artifact, upload 5 parts OUT OF ORDER with one part sent twice (retry simulation), finalize with the correct declared sha256 and size, then list and download.",
		"Assert from measured values: downloaded bytes are identical to the original (compare digests computed in the test), list shows exactly one artifact only AFTER finalize (assert list is empty before finalize), and a finalize with a WRONG digest on a second artifact is rejected and that artifact never appears in list.",
		"Print exactly one summary line: `artifacts_bytes=<n> digest_match=<true|false> visible_before_finalize=<count> bad_digest_visible=<count>` computed from the actual assertions.",
	]
	validations: [
		{kind: "integration", command: ["make", "results"], description: "artifacts round-trip green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "digest_match=true"},
			{kind: "stdout_contains", pattern: "visible_before_finalize=0"},
			{kind: "stdout_contains", pattern: "bad_digest_visible=0"},
		]},
	]
}

project: assets: CacheSemanticsTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_gateway/test/results/cache_semantics_test.exs — GitHub restore-key and scope-chain semantics, plus LRU eviction"
	uses: ["applicationService.Results.CacheApi", "domainService.Results.RestoreKeyResolver", "domainService.Results.LruEvictor", "adapter.LocalFsCacheStore", "adapter.GatewayHttpServer"]
	prompts: [
		"File path: apps/crest_ci_gateway/test/results/cache_semantics_test.exs.",
		"Boot a gateway replica with a LocalFsCacheStore in a temp dir. Over real HTTP: commit entries under distinct keys and scopes, then exercise: (1) exact-key hit; (2) restore-key longest-prefix hit choosing the most recent of two matches; (3) a lookup whose only matching key lives in a DIFFERENT branch scope not in the chain — must miss; (4) default-branch fallback hit from a feature-branch scope chain; (5) a miss returns the soft-miss shape, not an error; (6) fill past a small byte budget, run eviction, assert the oldest lastUsedAt entries were evicted and Reserved entries survived.",
		"Count scope violations (case 3 serving anything) and print exactly one line: `cache_exact_hits=<n> prefix_hits=<n> wrong_scope_hits=<n> soft_misses=<n> lru_order_violations=<n>` from measured outcomes.",
	]
	validations: [
		{kind: "integration", command: ["make", "results"], description: "cache semantics green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "wrong_scope_hits=0"},
			{kind: "stdout_contains", pattern: "lru_order_violations=0"},
		]},
	]
}

project: assets: ArchiveCompactionTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_gateway/test/results/archive_compaction_test.exs — exactly-once ordered archives from duplicated, reordered chunk ingest"
	uses: ["applicationService.Results.ArchiveOnComplete", "domainService.Results.LogCompactor", "applicationService.Gateway.LogIngest"]
	prompts: [
		"File path: apps/crest_ci_gateway/test/results/archive_compaction_test.exs.",
		"Ingest a job's log chunks across 3 steps with sequences delivered out of order and ~20% of chunks re-sent (duplicates). Complete the job and run ArchiveOnComplete twice (idempotency).",
		"Reconstruct the archive and assert: every (step, seq) appears exactly once; within each step seqs are 1..max in order; the second compaction changed nothing (same digest); live chunks are gone after archiving.",
		"Print exactly one line: `archived_lines=<n> duplicate_lines=<n> order_violations=<n> idempotent=<true|false>` from measured values.",
	]
	validations: [
		{kind: "integration", command: ["make", "results"], description: "archive compaction green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "duplicate_lines=0"},
			{kind: "stdout_contains", pattern: "order_violations=0"},
			{kind: "stdout_contains", pattern: "idempotent=true"},
		]},
	]
}

project: assets: ResultsE2EDemo: {
	kind:        "elixir-demo"
	description: "mix crest_ci.demo_results — two runs end-to-end: artifacts uploaded and verified, cache miss then hit, archives gapless, across the full in-BEAM stack"
	uses: ["aggregate.SimRunner.RunnerClient", "applicationService.Results.ArtifactsApi", "applicationService.Results.CacheApi", "applicationService.Results.ArchiveOnComplete", "asset.E2EDemo"]
	prompts: [
		"File path: apps/sim_runner/lib/mix/tasks/crest_ci.demo_results.ex (runnable as `mix crest_ci.demo_results`), reusing the E2E harness modules from the existing demo where sensible.",
		"Boot the full in-BEAM stack (mock-k8s, 3 controllers, 2 gateways, LocalFs stores in temp dirs). Execute TWO sequential WorkflowRuns whose job messages include steps of kind upload_artifact (a deterministic ~64KiB payload) and cache_restore + cache_save under the same key: run 1 must observe a cache miss then save; run 2 must observe a cache hit.",
		"After both runs verify from authoritative state: both runs Succeeded; the artifact from each run downloads byte-identical (digest comparison); run 2's cache_restore was a hit; every job's archive is gapless (reuse the compaction verification approach).",
		"Print exactly one summary line: `runs_succeeded=<n> artifacts_verified=<n> cache_hit_second_run=<true|false> archive_gaps=<n>` and exit non-zero unless runs_succeeded=2, artifacts_verified=2, cache_hit_second_run=true, archive_gaps=0.",
	]
	validations: [
		{kind: "integration", command: ["make", "demo-results"], description: "Results e2e: artifacts round-trip + cache hit + gapless archives across the full stack", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "runs_succeeded=2"},
			{kind: "stdout_contains", pattern: "artifacts_verified=2"},
			{kind: "stdout_contains", pattern: "cache_hit_second_run=true"},
			{kind: "stdout_contains", pattern: "archive_gaps=0"},
		]},
	]
}
