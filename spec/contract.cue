package crestci

// Contract — the shared kernel every component compiles against: CRD
// struct/schema types (API group ci.crest.dev/v1alpha1), phase machines,
// deterministic naming, the label schema, and the Kubernetes client port.
// Modules live under apps/crest_ci_contract/lib/crest_ci_contract/.

project: contexts: Contract: purpose: "CRD schemas, phase enums, deterministic child naming, label schema, and the Kubernetes API client port — the one vocabulary controller, gateway, mock server, and runner client all share"

project: contexts: Contract: meta: notes: "modules live in apps/crest_ci_contract/lib/crest_ci_contract/, tests in apps/crest_ci_contract/test/. Structs serialize to/from the Kubernetes JSON wire shape (camelCase keys, metadata/spec/status envelopes) via Jason."

project: contexts: Contract: ubiquitousLanguage: {
	WorkflowRun:     "one triggered execution of a workflow definition; owns a plan (expanded job DAG) and per-job statuses"
	RunnerJob:       "the queue element — the assignment record a gateway leases to exactly one runner; compute stays a plain Pod"
	JobKey:          "a job's path in the plan; matrix jobs are suffixed /m-<matrix hash>"
	Lease:           "time-bounded claim: coordination Lease for controller leadership, or the lease window on a RunnerJob"
	ResourceVersion: "monotonically increasing store version used for optimistic-concurrency CAS"
}

project: contexts: Contract: valueObjects: {
	// Identity + naming primitives
	Ulid: {from: "string", description: "26-character Crockford base32 ULID; generated from timestamp + randomness", invariants: [
		"exactly 26 characters from the Crockford base32 alphabet",
		"lexicographic order of ULIDs generated at different milliseconds matches creation order",
	]}
	JobKey: {from: "string", description: "job path within a plan, e.g. \"build\" or \"test/m-3f9a2c\"", invariants: [
		"safe to embed in a Kubernetes resource name after slugging: lowercased, / replaced by -, only [a-z0-9-]",
	]}

	// Kubernetes envelope
	ObjectMeta: {
		state: {name: "string", namespace: "string", uid: "string", resourceVersion: "string", labels: "map<string,string>", annotations: "map<string,string>", ownerReferences: "list<OwnerReference>", creationTimestamp: "string"}
		description: "the metadata envelope every stored object carries; mirrors Kubernetes ObjectMeta in camelCase JSON"
	}
	OwnerReference: {state: {apiVersion: "string", kind: "string", name: "string", uid: "string"}, description: "parent pointer for cascade semantics"}

	// Phase machines
	WorkflowRunPhase: {from: "enum", description: "Pending, Queued, Running, Succeeded, Failed, Cancelled", invariants: [
		"terminal phases (Succeeded, Failed, Cancelled) never transition to any other phase",
	]}
	JobPhase: {from: "enum", description: "Waiting, Queued, Assigned, Running, Succeeded, Failed, Cancelled, Skipped"}
	RunnerJobPhase: {from: "enum", description: "Queued, Leased, Acquired, Completed, Abandoned", invariants: [
		"legal transitions are exactly Queued->Leased, Leased->Acquired, Leased->Queued (lease expiry before ack, controller-only), Acquired->Completed, and {Leased,Acquired}->Abandoned (controller-only)",
	]}

	// WorkflowRun CRD
	PlanJob: {
		state: {key: "JobKey", displayName: "string", needs: "list<JobKey>", runsOn: "list<string>", steps: "list<map>"}
		description: "one node of the expanded job DAG carried in WorkflowRun spec.plan — hand-planned in this slice (the workflow engine lands in a later phase)"
	}
	WorkflowRunSpec: {
		state: {repo: "string", sha: "string", ref: "string", plan: "list<PlanJob>", concurrencyKey: "string", placement: "map"}
		description: "what to run; plan is the pre-expanded DAG"
	}
	JobStatus: {
		state: {phase: "JobPhase", queuedAt: "string", assignedRunner: "string", startedAt: "string", finishedAt: "string", outputs: "map<string,string>", logChunks: "int"}
		description: "per-job execution record inside WorkflowRun status; Assigned/Running/outputs fields are written by the gateway, orchestration fields by the controller"
	}
	WorkflowRunStatus: {
		state: {phase: "WorkflowRunPhase", jobs: "map<JobKey,JobStatus>"}
		description: "aggregate run state; run phase is derived from job phases"
	}

	// RunnerJob CRD
	RunnerJobSpec: {
		state: {runRef: "string", jobKey: "JobKey", runsOn: "list<string>", jobMessage: "map"}
		description: "the queue element spec; jobMessage carries the rendered protocol job payload the runner will execute"
	}
	RunnerJobStatus: {
		state: {phase: "RunnerJobPhase", leasedBy: "string", leaseExpiresAt: "string", acquiredAt: "string", result: "string"}
		description: "lease + acquisition record arbitrated by resourceVersion CAS"
	}

	// Coordination
	LeaseSpec: {
		state: {holderIdentity: "string", leaseDurationSeconds: "int", acquireTime: "string", renewTime: "string", leaseTransitions: "int"}
		description: "coordination.k8s.io Lease spec used for controller leader election"
	}
}

project: contexts: Contract: domainServices: {
	DeterministicNaming: {
		purpose: "derive child resource names: RunnerJob and pod for run <ulid> job <jobKey> is \"run-<ulid>-j-<slugged jobKey>\" — pure function, same inputs always same output"
		uses: ["valueObject.Contract.Ulid", "valueObject.Contract.JobKey"]
	}
	LabelSchema: {
		purpose: "build and parse the crest.dev/* label set (run ULID, job key slug, runs-on hash, cluster) so components filter by labels instead of parsing names"
		uses: ["valueObject.Contract.JobKey"]
	}
}

// The Kubernetes API client — shared by controller, gateway, and sim harnesses.
// One implementation (Req against any conformant API server: mock in tests,
// real cluster later); watch is a streamed sequence of decoded events.
project: contexts: Contract: ports: KubeClient: {
	contract: {
		get:          "(conn, gvk, namespace, name) -> {:ok, object} | {:error, :not_found | term}"
		list:         "(conn, gvk, namespace, opts) -> {:ok, [object], continue_token} | {:error, term}"
		create:       "(conn, gvk, namespace, object) -> {:ok, object} | {:error, :already_exists | term}"
		update:       "(conn, gvk, namespace, object) -> {:ok, object} | {:error, :conflict | term}"
		patch_status: "(conn, gvk, namespace, name, status, expected_resource_version) -> {:ok, object} | {:error, :conflict | term}"
		delete:       "(conn, gvk, namespace, name) -> :ok | {:error, term}"
		watch:        "(conn, gvk, namespace, from_resource_version, callback) -> {:ok, watch_ref} | {:error, :gone | term}"
	}
	meta: notes: "update and patch_status MUST surface optimistic-concurrency conflicts as {:error, :conflict}, and create MUST surface name collisions as {:error, :already_exists} — callers' idempotency depends on distinguishing these from transport errors"
}

project: adapters: ReqKubeClient: {
	implements: "port.Contract.KubeClient"
	layer:      "infrastructure"
	meta: {
		framework: "req"
		notes:     "speaks Kubernetes REST conventions: GET/POST/PUT/DELETE on /apis/<group>/<version>/namespaces/<ns>/<plural>, PATCH or PUT on /status subresource, watch via ?watch=true chunked JSON lines from a resourceVersion. Lives in apps/crest_ci_contract so every app reuses it."
	}
}
