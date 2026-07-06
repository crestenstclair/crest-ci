package crestci

// MockK8s — an in-memory Kubernetes API server implementing exactly the
// semantics the controller and gateway rely on: typed storage with monotonic
// resourceVersions, optimistic-concurrency CAS, the status subresource,
// list pagination, and watch streams. It is the test-time stand-in for a real
// cluster; the conformance suite below is what licenses that substitution.
// Modules live under apps/mock_k8s/lib/mock_k8s/.

project: contexts: MockK8s: purpose: "in-memory Kubernetes API server: resource store with etcd-like versioning semantics, watch fan-out, and an HTTP facade speaking Kubernetes REST conventions"

project: contexts: MockK8s: meta: notes: "modules live in apps/mock_k8s/lib/mock_k8s/, tests in apps/mock_k8s/test/. The server binds an ephemeral port via start_link(port: 0) and reports the bound port; tests and the demo never hard-code ports."

project: contexts: MockK8s: ubiquitousLanguage: {
	ResourceVersion: "store-wide monotonic counter stamped on every write; the CAS token"
	WatchEvent:      "ADDED | MODIFIED | DELETED envelope carrying the object at its new resourceVersion"
	ContinueToken:   "opaque cursor for chunked list pagination"
}

project: contexts: MockK8s: aggregates: {
	ResourceStore: {
		root:    true
		purpose: "the single authoritative object store: all reads, writes, and CAS arbitration for every group/version/kind"
		state: {objects: "map<{gvk,namespace,name}, object>", currentResourceVersion: "u64"}
		commands: [
			{name: "Create", payload: {gvk: "string", namespace: "string", object: "map"}},
			{name: "Update", payload: {gvk: "string", namespace: "string", object: "map"}},
			{name: "PatchStatus", payload: {gvk: "string", namespace: "string", name: "string", status: "map", expectedResourceVersion: "string"}},
			{name: "Delete", payload: {gvk: "string", namespace: "string", name: "string"}},
		]
		events: [
			{name: "ResourceWritten", payload: {type: "ADDED|MODIFIED|DELETED", object: "map", resourceVersion: "string"}},
		]
		invariants: [
			"resourceVersion increases strictly monotonically across ALL writes to the store, regardless of kind",
			"Create of an existing (gvk, namespace, name) fails with already_exists (HTTP 409, reason AlreadyExists)",
			"Update or PatchStatus whose expected resourceVersion does not match the stored object fails with conflict (HTTP 409, reason Conflict) and mutates nothing",
			"PatchStatus replaces only the status subtree — spec and metadata (except resourceVersion) are untouched; Update via the main resource never modifies status",
			"every successful write emits exactly one WatchEvent carrying the object stamped with its new resourceVersion",
			"List with a limit returns at most limit items plus a continue token; continuing enumerates every object exactly once even if unrelated writes happen between pages",
		]
	}
	WatchHub: {
		purpose: "fan out ResourceWritten events to watch subscribers, ordered and resumable"
		state: {subscribers: "map<watch_ref, {gvk, namespace, last_delivered_rv}>", backlog: "bounded event history per gvk"}
		commands: [
			{name: "Subscribe", payload: {gvk: "string", namespace: "string", fromResourceVersion: "string"}},
			{name: "Unsubscribe", payload: {watchRef: "ref"}},
		]
		invariants: [
			"a subscriber receives events strictly in resourceVersion order with no gaps for its (gvk, namespace) scope",
			"subscribing from a resourceVersion older than the retained backlog fails with gone (HTTP 410) — the client must relist",
			"a slow subscriber never blocks writers — delivery is asynchronous with a bounded mailbox; overflow terminates that watch, never the store",
		]
	}
}

project: contexts: MockK8s: ports: KubeApiHttp: {
	contract: {
		serve: "(store, port) -> {:ok, server} — HTTP facade exposing Kubernetes REST conventions over the ResourceStore"
	}
	meta: notes: "routes: CRUD + list on /apis/{group}/{version}/namespaces/{ns}/{plural} (and /api/v1 for core kinds), /status subresource via PUT/PATCH, ?watch=true streaming chunked JSON lines, ?limit=&continue= pagination. Registered kinds: WorkflowDefinition/WorkflowRun/RunnerJob/RunnerPool (ci.crest.dev/v1alpha1), Lease (coordination.k8s.io/v1), Pod/Secret/ConfigMap (core/v1). Error bodies follow the Kubernetes Status object shape with reason AlreadyExists/Conflict/NotFound/Gone."
}

project: adapters: MockK8sHttpServer: {
	implements: "port.MockK8s.KubeApiHttp"
	layer:      "infrastructure"
	meta: {
		framework: "plug + bandit"
		notes:     "watch responses stream one JSON object per line and honor client disconnect; the Plug router is thin — all semantics live in ResourceStore/WatchHub"
	}
}

// The conformance suite is what licenses using MockK8s in place of a real
// cluster everywhere else in the repo.
project: assets: MockK8sConformanceTests: {
	kind:        "elixir-test-suite"
	description: "apps/mock_k8s/test/conformance_test.exs — proves the store semantics every other component's correctness rests on"
	uses: ["aggregate.MockK8s.ResourceStore", "aggregate.MockK8s.WatchHub", "adapter.MockK8sHttpServer", "adapter.ReqKubeClient"]
	prompts: [
		"File path: apps/mock_k8s/test/conformance_test.exs (plus helpers under apps/mock_k8s/test/support/ if needed).",
		"Exercise the server END TO END through the ReqKubeClient adapter over real HTTP on an ephemeral port — not by calling the store directly — so the client and server are conformance-tested against each other.",
		"Prove, with explicit assertions on returned values: (1) resourceVersions from a sequence of writes are strictly increasing integers across mixed kinds; (2) create-then-create returns {:error, :already_exists}; (3) patch_status with a stale resourceVersion returns {:error, :conflict} and a follow-up get shows the object unchanged; (4) patch_status changes status but leaves spec byte-identical; (5) a watch opened before N writes delivers exactly N events in resourceVersion order (assert the actual ordered list, not just the count); (6) watch from an expired resourceVersion returns {:error, :gone}; (7) paginated list with limit 2 over 7 objects yields all 7 exactly once across pages; (8) two concurrent CAS updates against the same resourceVersion — exactly one succeeds and exactly one returns {:error, :conflict}.",
		"Each numbered behavior is its own test; failures must identify the violated semantic.",
	]
	validations: [
		{kind: "integration", command: ["make", "conformance"], description: "conformance suite green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "0 failures"},
		]},
	]
}
