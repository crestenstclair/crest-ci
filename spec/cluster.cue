package crestci

// Cluster — real Kubernetes. Until now everything ran in-BEAM against the mock
// API server; this slice makes crest-ci deploy to and drive a real k3d cluster
// (k3s-in-Docker), creating ACTUAL ephemeral runner Pods that dial the gateway
// over real cluster networking and execute a planned WorkflowRun's job DAG.
//
// The runner in THIS slice is our SimRunner packaged as a container image
// (the "real cluster, our runner first" decision) — proving pod orchestration,
// real KubeClient auth, cross-pod networking, and HA on genuine k3s. Swapping
// in the official actions/runner + its Actions-service protocol is a later
// slice (D2 §6/§8, the central bet).
//
// GATE POLICY: the commit gate stays pure-mix. Everything that needs Docker/k3d
// (image build, cluster up, real deploy, demo-k3d) is a MANUAL make target,
// never run in a wave's validation. The generatable, mix-provable pieces are:
// the kubeconfig->conn loader, the pure Pod-spec builder, and the real-cluster
// orchestrator (tested against mock-k8s). The Dockerfile, k8s manifests, k3d
// config, and demo harness are assets whose validation is a mix-runnable
// structural check only.
// Modules live under apps/crest_ci_controller/lib/crest_ci_controller/cluster/.

project: contexts: Cluster: purpose: "deploy to and drive a real k3d cluster: load real kubeconfig credentials into a KubeClient conn, build real ephemeral runner Pod specs from RunnerJobs, and orchestrate scale-per-job Pod creation against a live API server"

project: contexts: Cluster: meta: notes: "modules live in apps/crest_ci_controller/lib/crest_ci_controller/cluster/, tests in apps/crest_ci_controller/test/cluster/. The real KubeClient adapter (adapter.ReqKubeClient) already speaks Kubernetes REST — it drives k3s unchanged; this context adds the auth/loading and pod-shaping around it. No new runtime deps beyond what ReqKubeClient uses; kubeconfig YAML parsing may use yaml_elixir (already a controller dep)."

project: contexts: Cluster: ubiquitousLanguage: {
	Kubeconfig:    "the standard kubeconfig file: cluster server URL + CA, and user credentials (client cert/key or bearer token)"
	ClusterConn:   "a KubeClient conn carrying real TLS + auth, usable against a live API server"
	RunnerPodSpec: "the concrete k8s Pod manifest for one RunnerJob: ephemeral, restartPolicy Never, the runner image, gateway URL + JIT identity via env"
}

project: contexts: Cluster: valueObjects: {
	ClusterCredential: {
		state: {server: "string", caData: "string", authKind: "enum: ClientCert, BearerToken", clientCertData: "string", clientKeyData: "string", token: "string", insecureSkipTlsVerify: "bool"}
		description: "resolved connection material for one cluster, extracted from a kubeconfig context; the future multi-cluster capacity slot (D2 §14) is a map of these"
	}
	RunnerPodSpec: {
		state: {name: "string", namespace: "string", image: "string", labels: "map<string,string>", env: "map<string,string>", cpuRequest: "string", cpuLimit: "string", memRequest: "string", memLimit: "string", activeDeadlineSeconds: "int", serviceAccount: "string"}
		description: "the fields the controller renders into a real Pod object for one RunnerJob; laptop profile defaults per D2 §10 (requests 100m/256Mi, limits 500m/768Mi)"
	}
}

project: contexts: Cluster: domainServices: {
	KubeconfigLoader: {
		purpose: "pure: (kubeconfig YAML string, context name or nil for current-context) -> {:ok, ClusterCredential} | {:error, reason}; extracts server, CA, and either client-cert/key or token; a malformed or context-missing config is a structured error"
		uses: ["valueObject.Cluster.ClusterCredential"]
	}
	PodSpecBuilder: {
		purpose: "pure: (RunnerJob, image, gateway_url, namespace, resource profile) -> RunnerPodSpec; pod name == RunnerJob name (deterministic), ownerReference back to the RunnerJob, runs-on labels copied for scheduling, env carries GATEWAY_URL + the runner identity/JIT bundle + DEMO/headless flags; ephemeral (restartPolicy Never), activeDeadlineSeconds = job timeout + slack"
		uses: ["valueObject.Contract.RunnerJobSpec", "valueObject.Cluster.RunnerPodSpec", "domainService.Contract.DeterministicNaming"]
	}
}

project: contexts: Cluster: applicationServices: {
	ClusterConnBuilder: {
		purpose: "turn a ClusterCredential into a KubeClient conn the ReqKubeClient adapter accepts: assembles the Req client with base URL, CA trust (or insecure skip), and client-cert or bearer auth; the single seam where real-cluster TLS enters — mock-k8s conns bypass it"
		uses: ["domainService.Cluster.KubeconfigLoader", "port.Contract.KubeClient", "adapter.ReqKubeClient"]
	}
	RealPodOrchestrator: {
		purpose: "the scale-per-job orchestration against a real cluster: on a Queued RunnerJob, render its RunnerPodSpec and create the Pod via KubeClient (409 AlreadyExists tolerated as success — deterministic name); on RunnerJob terminal, the Pod is garbage-collected by its ownerReference. Mirrors the in-BEAM demo orchestration but emits real Pod objects; identical reconcile logic, different conn"
		uses: ["domainService.Cluster.PodSpecBuilder", "port.Contract.KubeClient", "applicationService.Controller.RunReconciler"]
	}
}

project: contexts: Cluster: invariants: [
	"real-cluster orchestration reuses the SAME reconcile logic as the in-BEAM path — only the KubeClient conn differs; there is no separate real-vs-mock control flow to drift",
	"a runner Pod is named exactly for its RunnerJob and carries an ownerReference to it, so failover re-creates are 409 no-ops and Pod cleanup is automatic on RunnerJob deletion",
	"credentials never appear in a Pod spec's plain env or in logs — the JIT identity is injected as it is for the in-BEAM runner, and kubeconfig secrets stay in the controller's conn",
	"the pod-spec builder is pure and deterministic: same RunnerJob + profile always yields the same manifest, so a real deploy is reproducible",
]

// ── mix-gate assets (structural/behavioral, no Docker) ─────────────────────────

project: assets: PodSpecUnitTest: {
	kind:        "elixir-test-suite"
	description: "apps/crest_ci_controller/test/cluster/pod_spec_test.exs — the pod-spec builder and kubeconfig loader, proven in the mix gate"
	uses: ["domainService.Cluster.PodSpecBuilder", "domainService.Cluster.KubeconfigLoader", "applicationService.Cluster.RealPodOrchestrator", "adapter.MockK8sHttpServer"]
	prompts: [
		"File path: apps/crest_ci_controller/test/cluster/pod_spec_test.exs (fixtures under apps/crest_ci_controller/test/cluster/fixtures/ — include a realistic kubeconfig YAML with both a client-cert user and a token user).",
		"Prove with assertions: (1) KubeconfigLoader extracts server/CA/auth for current-context and for a named context, and errors structurally on a missing context; (2) PodSpecBuilder yields pod name == RunnerJob name, an ownerReference to the RunnerJob, runs-on labels copied, GATEWAY_URL + identity present in env, restartPolicy-equivalent ephemeral fields set, and laptop-profile resource requests/limits; (3) building the same RunnerJob twice yields byte-identical specs; (4) RealPodOrchestrator, driven against a MockK8s server, creates exactly one Pod object per RunnerJob and treats a second create as success (409 tolerated) — assert exactly one Pod exists after a double reconcile.",
		"Print exactly one line: `pod_specs_built=<n> deterministic=<true|false> duplicate_pods=<n> kubeconfig_contexts=<n>` and assert deterministic=true, duplicate_pods=0.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "pod-spec + kubeconfig + orchestrator unit suite green", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "deterministic=true"},
			{kind: "stdout_contains", pattern: "duplicate_pods=0"},
		]},
	]
}

// ── out-of-gate infra assets (Docker/k3d; mix-provable structural check only) ──

project: assets: CrdManifests: {
	kind:        "makefile"
	description: "deploy/crds/*.yaml — CustomResourceDefinitions for the four ci.crest.dev kinds, installable into a real cluster"
	uses: ["valueObject.Contract.WorkflowRunSpec", "valueObject.Contract.RunnerJobSpec"]
	prompts: [
		"Files: deploy/crds/workflowrun.yaml, deploy/crds/runnerjob.yaml, deploy/crds/runnerpool.yaml, deploy/crds/workflowdefinition.yaml — apiextensions.k8s.io/v1 CustomResourceDefinition manifests for group ci.crest.dev, version v1alpha1, each with a status subresource and an openAPIV3Schema whose spec/status fields MATCH the contract structs (WorkflowRunSpec/Status, RunnerJobSpec/Status, etc.). Use x-kubernetes-preserve-unknown-fields for the free-form map/plan subtrees.",
		"Also write apps/crest_ci_controller/test/cluster/crd_manifest_test.exs: parse each YAML (yaml_elixir), assert kind==CustomResourceDefinition, group==ci.crest.dev, a status subresource is declared, and the named plural/kind match the contract. Print `crds=<n> with_status=<n>` and assert they are equal and >=4.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "CRD manifests structurally valid (parsed in mix, no cluster)", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "crds=4"},
		]},
	]
}

project: assets: RunnerImage: {
	kind:        "makefile"
	description: "deploy/runner/Dockerfile + entrypoint — packages the SimRunner client as an ephemeral runner image"
	uses: ["aggregate.SimRunner.RunnerClient"]
	prompts: [
		"Files: deploy/runner/Dockerfile and deploy/runner/entrypoint.sh.",
		"The Dockerfile builds a small OCI image from an Elixir/OTP base that contains a release (or escript) of the sim_runner app. The entrypoint reads GATEWAY_URLS and the JIT/identity bundle from env (the same env the PodSpecBuilder injects), then starts one RunnerClient that executes exactly its one job and exits — mirroring `run.sh --jitconfig` shape but for our client. restartPolicy Never at the pod level means the container runs once.",
		"Non-root user, no secrets baked into layers. Include a build-arg for the sim_runner source path so `make k3d-load` can build it from the umbrella.",
		"Also write apps/crest_ci_controller/test/cluster/runner_image_test.exs: read the Dockerfile + entrypoint as text and assert the contract — non-root USER set, ENTRYPOINT/CMD invokes the entrypoint, entrypoint references GATEWAY_URLS and the identity env var names the PodSpecBuilder emits (keep the two in sync — the test cross-checks the builder's env keys against the entrypoint). Print `dockerfile_ok=true env_keys_matched=<n>` and assert env_keys_matched>=2.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "runner image contract check (text/structure, no docker build)", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "dockerfile_ok=true"},
		]},
	]
}

project: assets: DeployManifests: {
	kind:        "makefile"
	description: "deploy/k8s/*.yaml — namespaces, RBAC, and controller/gateway Deployments for a real cluster"
	uses: ["applicationService.Cluster.RealPodOrchestrator"]
	prompts: [
		"Files under deploy/k8s/: namespaces.yaml (crest-ci-system, crest-ci-runners), rbac.yaml (the crest-runner ServiceAccount + a Role granting the narrow pod create/watch/exec in crest-ci-runners that container-hooks needs, plus the controller's ClusterRole for CRDs/pods/leases), controller.yaml (Deployment x3, leader-elected, mounting its in-cluster ServiceAccount), gateway.yaml (Deployment x2 active-active + a Service the runner Pods dial).",
		"Real values consistent with the rest of the repo: image names match RunnerImage/build outputs, the gateway Service name is what PodSpecBuilder puts in GATEWAY_URLS, namespaces match what RealPodOrchestrator targets.",
		"Also write apps/crest_ci_controller/test/cluster/deploy_manifest_test.exs: parse all manifests, assert both namespaces present, the crest-runner SA + its pod-create RBAC exist and are scoped to crest-ci-runners, controller replicas==3 and gateway replicas==2, and the gateway Service name equals the host PodSpecBuilder emits in GATEWAY_URLS (cross-check against the builder). Print `manifests=<n> gateway_service_matches=<true|false>` and assert gateway_service_matches=true.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "deploy manifests structurally valid + cross-checked (no cluster)", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "gateway_service_matches=true"},
		]},
	]
}

project: assets: K3dBootstrap: {
	kind:        "makefile"
	description: "k3d cluster config + Makefile targets for the whole real-cluster lifecycle (manual, out-of-gate)"
	uses: ["asset.DeployManifests", "asset.RunnerImage", "asset.CrdManifests"]
	prompts: [
		"Files: deploy/k3d/cluster.yaml (a k3d cluster config: one server, memory-capped agents, a built-in registry, host port mappings so the gateway Service is reachable) and Makefile targets appended to the root Makefile.",
		"Makefile targets (all MANUAL — never invoked by the mix gate): `k3d-up` (k3d cluster create from the config + kubectl apply the CRDs + deploy/k8s manifests), `k3d-load` (build the runner image and import it into the k3d registry), `k3d-down` (k3d cluster delete), `k3d-status` (kubectl get pods across both namespaces). Guard each with a check that docker + k3d are installed, printing a clear message if not.",
		"Keep these targets OUT of the default/test/check targets so `make test` never touches Docker.",
		"Also write apps/crest_ci_controller/test/cluster/k3d_config_test.exs: parse deploy/k3d/cluster.yaml and assert it declares a registry and at least one server node; grep the Makefile to assert the k3d-up/k3d-load/k3d-down targets exist and that none of them are prerequisites of `test`/`check`/`demo-e2e`. Print `k3d_targets=<n> gate_isolation=true|false` and assert gate_isolation=true.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "k3d config + Makefile target isolation check (no cluster)", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "gate_isolation=true"},
		]},
	]
}

project: assets: DemoK3d: {
	kind:        "elixir-demo"
	description: "mix crest_ci.demo_k3d + make demo-k3d — submit a real WorkflowRun to a live k3d cluster and watch real Pods execute it (manual, out-of-gate)"
	uses: ["applicationService.Cluster.ClusterConnBuilder", "applicationService.Cluster.RealPodOrchestrator", "applicationService.Controller.PlanFromDefinition", "asset.K3dBootstrap"]
	prompts: [
		"Files: apps/sim_runner/lib/mix/tasks/crest_ci.demo_k3d.ex (runnable as `mix crest_ci.demo_k3d`) and a `demo-k3d` Makefile target that runs it after asserting the cluster is up.",
		"Behavior: load the current kubeconfig via ClusterConnBuilder (pointing at the k3d cluster), submit a WorkflowRun carrying a real workflow YAML (reuse the scene workflow library — a build->test->deploy chain), let the deployed controller plan it and create REAL runner Pods, and watch — polling the real API — until the run reaches a terminal phase. Verify from authoritative cluster state: the expected Pods were created (one per planned job, correct deterministic names), each job Succeeded, and Pod cleanup happened via ownerReferences after completion.",
		"Print exactly one line: `k3d_runs_succeeded=<n> pods_created=<n> pods_cleaned=<n> jobs_succeeded=<n>` from real cluster observation, and exit non-zero unless k3d_runs_succeeded=1 and jobs_succeeded equals the planned job count. This target is MANUAL — its only mix-gate validation is that the task compiles (covered by mix compile); it must NOT run k3d in a wave.",
		"Because the gate cannot run k3d, give this asset a mix-only structural validation: apps/sim_runner/test/cluster/demo_k3d_test.exs that asserts the mix task module exists and exposes run/1, and that the demo-k3d Makefile target is not a prerequisite of test/check. Print `demo_k3d_compiles=true gated_out=true` and assert both.",
	]
	validations: [
		{kind: "integration", command: ["make", "cluster-unit"], description: "demo-k3d task present + gate-isolated (compiles in mix; k3d run is manual)", assertions: [
			{kind: "exit_code", expected: 0},
			{kind: "stdout_contains", pattern: "demo_k3d_compiles=true"},
			{kind: "stdout_contains", pattern: "gated_out=true"},
		]},
	]
}
