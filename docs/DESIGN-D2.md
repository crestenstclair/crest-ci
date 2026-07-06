# crest-ci: High-Availability, Fully-Compatible GitHub Actions Control Plane

**Technical Specification — Draft 2**
*Working name `crest-ci`; final name must not contain "GitHub" (trademark). Draft 2 supersedes Draft 1: full Actions compatibility is now a primary goal, job execution is the core deliverable, the runner layer is built from GitHub's own open-source runner stack (ARC lineage), and multi-cluster scheduling is a designed-for extension.*

> Note: this is the input design document for the crest-spec CUE spec in `spec/`.
> The current spec covers the **M0–M2 slice** (contract, mock-k8s, controller
> skeleton, gateway v0, SimRunner e2e). Later milestones extend the spec.

---

## 1. Overview

crest-ci is a self-hosted, high-availability replacement for the GitHub Actions **service**. It executes real Actions workflows — including reusable workflows, matrices, composite actions, container jobs, and service containers — by running GitHub's unmodified open-source runner against a reimplementation of the server-side protocol. All control-plane state lives in CRDs (etcd is the only database). Results appear natively on GitHub PRs via the Checks API; a Phoenix LiveView dashboard is the primary UI.

### 1.1 The Central Architectural Bet

**We do not reimplement job execution. We reimplement the service the official runner talks to.**

GitHub's runner (`actions/runner`, MIT) is where most of "Actions compatibility" actually lives: step execution, step-level `${{ }}` expression evaluation, composite actions, JavaScript actions (bundled Node runtimes), Docker actions, action download/extraction, `container:` jobs and `services:` (via `runner-container-hooks`, MIT, Kubernetes mode), problem matchers, step outputs/summaries, post/pre steps, path/env file commands. By running that binary unmodified, all of it is byte-for-byte compatible by construction and tracks upstream by bumping a pinned runner version.

What the runner does *not* contain — and what we therefore build — is the server side:

1. **Workflow engine** — YAML parsing, workflow-level expression evaluation, `strategy.matrix` expansion, `needs` DAG, **reusable workflows** (`workflow_call`), `concurrency` groups, contexts assembly, secrets/vars injection. (§5)
2. **Runner Gateway** — the Actions service protocol: runner sessions, job message long-poll queues, job acquisition, timeline updates, live log ingest. The client side of this protocol is fully visible in the MIT-licensed runner source; the gateway is written against a **pinned runner version** with a conformance suite derived from that source. (§6)
3. **Results-compatible services** — log upload, **artifacts v4** (`upload-artifact@v4` protocol), **cache service** (`actions/cache@v4` protocol), backed by S3/MinIO. (§7)
4. **Orchestration** — the HA control plane that turns `WorkflowRun` CRs into ephemeral runner pods, ARC-style. (§4, §8)

Because runners dial **outbound** to the gateway (long-poll HTTP), runner pods can live in any cluster — or on bare metal, or on a Windows/macOS box someone registers — without the control plane reaching into their network. This is what makes multi-cluster scheduling (§14) an extension rather than a rewrite, and it means non-Linux runners work the moment someone points one at the gateway, even though we only *manage* Linux pods in v1.

### 1.2 Goals

- **G1 — Availability:** No SPOF. Leader failover ≤ 20 s, zero lost or duplicated runs. Gateway is multi-replica active-active (§6.6): in-flight jobs survive controller failover.
- **G2 — Full workflow compatibility:** Real-world workflows run unmodified. Phased compat matrix in §5.6; "full" explicitly includes reusable workflows, matrix, composite actions, container jobs, services, artifacts v4, cache, step summaries, concurrency groups.
- **G3 — Statelessness:** All authoritative state in CRDs + object storage. Any component killable at any time.
- **G4 — Contract-separated dashboard:** Dashboard and control plane share only the CRD contract, object storage, and one documented live-log relay endpoint (§7.4).
- **G5 — Native GitHub presence:** Check runs per job via Checks API, `details_url` into the dashboard.
- **G6 — Demonstrable scale:** Mock K8s + protocol-real simulated runners drive unmodified binaries to ≥ 50 000 concurrent jobs on demo hardware.
- **G7 — Local developability:** Whole system on a laptop (k3d) or demo box (mock) inside hard resource budgets that cannot take down the host.
- **G8 — Multi-cluster-ready:** Placement is a first-class field from v1; the scheduler that fills it non-trivially comes later (§14).

### 1.3 Non-Goals (v1) — narrowed

- Hosted-runner *fleet management* for Windows/macOS (protocol supports them; we don't provision those machines — bring-your-own runner works).
- GitHub-hosted larger-runner billing semantics, GitHub Enterprise-side features (required workflows, org rulesets enforcement).
- OIDC token minting for cloud federation (v1.1 — designed-for: the gateway owns the token endpoint the runner already calls; issuing signed JWTs with our own issuer is an add-on, not a rework).
- Environments with protection rules/approvals (v1.1; CRD fields reserved).
- Web-based workflow editing.

### 1.4 Component Inventory

| # | Project | Language | Runs as | New in D2 |
|---|---------|----------|---------|-----------|
| 1 | Control plane `crest-ci-controller` (reconcilers, workflow engine, webhook ingest, Checks bridge, TTL sweeper) | Elixir, Bonny, libcluster | Deployment ×3, leader-elected | workflow engine |
| 2 | **Runner Gateway** `crest-ci-gateway` (runner protocol + Results + artifacts + cache + log relay) | Elixir, Phoenix (API-only) | Deployment ×N, **active-active, no election** | ★ |
| 3 | Dashboard `crest-ci-dashboard` | Elixir, Phoenix LiveView | Deployment ×N, no election | log source changed |
| 4 | Runner image `crest-ci-runner-image` (pinned `actions/runner` + `runner-container-hooks` + entrypoint) | Dockerfile + shell | Ephemeral pods | ★ |
| 5 | Mock K8s + simulator `crest-ci-mock-k8s` (+ **SimRunner** protocol client) | Elixir, Plug/Bandit | demo/test container | SimRunner ★ |
| 6 | Browser extension `crest-ci-extension` | MV3 TS | sideloaded | unchanged |
| 7 | Contract `crest_ci_contract` (CRDs, structs, label schema, conversions) | Elixir | hex dep of 1–3,5 | new CRDs |

Gateway is a **separate deployment** from the controller because its scaling model is opposite (stateless active-active, connection-heavy, scales with concurrent runners) and its availability requirement is stricter (a gateway outage pauses *all running jobs'* progress reporting; a controller outage only pauses *new* scheduling).

### 1.5 Upstream Reuse Manifest ("rip everything possible off ARC")

| Upstream | License | What we take | What we replace |
|---|---|---|---|
| `actions/runner` | MIT | The entire binary, unmodified, pinned (e.g. `v2.3xx`). JIT-config (`--jitconfig`) startup path. Its source = protocol reference + conformance vectors. | The service it talks to (our gateway). |
| `actions/runner-container-hooks` | MIT | `k8s` hook package verbatim → `container:` jobs & `services:` run as pods, no DinD. | nothing |
| ARC (`actions/actions-runner-controller`) | Apache-2.0 | Ephemeral-runner pod spec conventions (work volume, hook env, security context), JIT-registration flow shape, listener→scale loop *pattern*, RBAC shapes, DinD-vs-k8s mode matrix, autoscaling semantics (min/max, scale on queued jobs) for §8.5. NOTICE-file attribution for anything ported. | The listener itself (talked to GitHub's service; ours talks to our own queue — trivially), their CRD API (ours differ), Helm charts. |
| `actions/languageservices` (expressions + workflow parser) | MIT | Expression grammar/function semantics + **test data as conformance vectors** for our Elixir evaluator; workflow schema knowledge. | Implementation (theirs is TS; ours Elixir). |
| `nektos/act` / Forgejo runner | MIT | Study-only: catalog of known compat gaps to avoid repeating. | Not used at runtime (their execution model is the road we're *not* taking). |
| OSS GH-cache-server reimplementations | various | Protocol notes for cache v2 API. | Implementation (ours is S3-native Elixir). |

Rule: anything ported from Apache-2.0 sources keeps headers + NOTICE. Runner and hooks are consumed as released artifacts, checksummed in the image build.

---

## 2. System Architecture

```
                 ┌────────────────────────────────────────────┐
                 │              Kubernetes API                 │
                 │        (real: k3s/EKS   |   mock)           │
                 └───────┬───────────────────────────┬─────────┘
        list/watch/CRUD  │                           │ list/watch + small writes
                 ┌───────┴────────────┐      ┌───────┴───────────────┐
                 │ crest-ci-controller│      │  crest-ci-dashboard   │
                 │ ×3, Lease leader   │      │  ×N, informer cache   │
                 │ • workflow engine  │      │  • LiveView + JSON API│
                 │ • run reconciler   │      │  • live logs via relay│
                 │ • pod orchestration│      └───────┬───────────────┘
                 │ • Checks bridge    │              │ SSE (log relay, §7.4)
                 │ • webhook ingest   │              │ + S3 archives
                 └───────┬────────────┘      ┌───────┴───────────────┐
                creates  │  runner pods      │   crest-ci-gateway    │
                 ┌───────┴────────────┐      │  ×N active-active     │
                 │  Ephemeral runner  │      │  • runner protocol    │
                 │  pods (official    │◀────▶│  • job queues (etcd-  │
                 │  actions/runner,   │ HTTPS│    backed via CRs)    │
                 │  JIT config,       │ out- │  • Results: logs      │
                 │  container-hooks)  │ bound│  • artifacts v4       │
                 └───────┬────────────┘      │  • cache API          │
                         │ container: jobs   │  • action dl proxy    │
                         ▼ as sibling pods   └───────┬───────────────┘
                 ┌────────────────────┐              │
                 │ crest-ci-runners ns│      ┌───────┴───────────────┐
                 └────────────────────┘      │ Object storage (S3/   │
                                             │ MinIO): logs, arti-   │
   GitHub ◀── Checks API (controller)        │ facts, cache, action  │
   Extension: URL redirects → dashboard      │ tarball cache         │
                                             └───────────────────────┘
```

### 2.1 Data-Flow Invariants (amended from D1)

1. **The K8s API is the interface between controller and dashboard** — no exceptions except invariant 5.
2. **Reconciliation is level-triggered and idempotent**; replaying events in any order converges.
3. **Deterministic child names** (`run-<ulid>-j-<jobPath>-<matrixHash>`): failover re-reconciles produce 409 no-ops, never duplicates.
4. **Deletion via finalizers**: pods cancelled → logs/artifacts flushed → checks concluded → finalizer removed.
5. **Documented exception — live-log relay:** the gateway exposes one read-only, offset-resumable SSE endpoint for in-flight job logs (§7.4). Dashboard uses it for live tails only; if the gateway is down, the dashboard degrades to archived logs. This exists because with the real runner, logs flow runner→gateway, not through kubelet — D1's kubelet-follow path is gone.
6. **Gateway holds no authoritative state.** Job queues, session identity, and job assignment are projections of CRs (§6.6); any gateway replica can serve any runner at any moment.

### 2.2 Failure-Domain Matrix (delta from D1)

| Failure | Behavior |
|---|---|
| Gateway replica dies | Runner long-poll reconnects to another replica (Service LB); session re-validated from CR-derived state; in-flight log chunk re-sent (chunk upload is idempotent by `(job, step, chunkSeq)`) |
| **All** gateways die | Running jobs keep executing on runners; runner buffers/retries uploads (runner-native behavior); progress reporting resumes on gateway return; job acquisition pauses |
| Controller leader dies | As D1: Lease failover ≤ 20 s; gateway unaffected — **running jobs don't notice controller failover at all** |
| Runner pod dies mid-job | Gateway session heartbeat lapse → job marked failed (or re-queued per `spec.retries`) by controller on next reconcile |
| S3 down | Artifact/cache/log-archive ops fail → runner retries; cache misses are soft (jobs proceed); artifacts hard-fail the step (matches GitHub) |
| GitHub API down | unchanged from D1 (checks queue + retry) |

Namespaces, contract-package rules, and controller cluster formation/Lease election are unchanged from D1 (§4.2–4.3 there) and restated in §4 only where modified.

---

## 3. CRD Design (revised)

API group `ci.crest.dev`, version `v1alpha1`, status subresources on everything.

### 3.1 `WorkflowDefinition` — unchanged shape from D1, richer `parsed` IR

`parsed` now captures the full schema: `on` with all trigger filters/activity types, `permissions`, `env`, `defaults`, `concurrency`, and per job: `uses` (reusable-workflow ref) **or** `steps`, `strategy` (matrix incl. `include`/`exclude`, `fail-fast`, `max-parallel`), `container`, `services`, `environment`, `outputs`, `secrets` mapping, `permissions`, `if`, `timeout-minutes`, `continue-on-error`, `runs-on` (labels array / group). Raw YAML retained verbatim. `Valid=False` condition + check-run feedback on parse errors (unchanged D1 policy).

### 3.2 `WorkflowRun` — jobs become a flattened, matrix- and reuse-expanded DAG

```yaml
spec:
  definitionRef: {name: wfd-…}; definitionGeneration: 7
  repo: acme/widgets; sha: …; ref: refs/pull/412/head
  event: {type: pull_request, payloadRef: {configMap: evt-…}}
  trigger: {actor: cresten, deliveryId: gh-uuid}
  concurrencyKey: "pr-412-build"        # engine-rendered; cancellation semantics §5.4
  placement: {cluster: "local"}         # G8: present from v1, trivial scheduler fills it (§14)
status:
  phase: Pending|Queued|Running|Succeeded|Failed|Cancelled
  plan:                                  # engine output: the expanded DAG (§5)
    jobs:
      - key: "build"                     # jobPath; matrix jobs: "test/m-3f9a2c"
        displayName: "test (ubuntu-24.04, otp-27)"
        needs: ["build"]
        matrix: {os: ubuntu-24.04, otp: "27"}
        callPath: []                     # reusable-workflow ancestry, e.g. ["ci","deploy-reusable"]
        runsOn: ["self-hosted","linux","x64"]
  jobs:
    "test/m-3f9a2c":
      phase: Waiting|Queued|Assigned|Running|Succeeded|Failed|Cancelled|Skipped
      queuedAt: …; assignedRunner: "run-…-j-test-m3f9a2c"; startedAt: …
      checkRunId: 98765
      outputs: {version: "1.4.2"}        # job outputs, feed `needs` context
      steps: [...]                       # written by gateway-side status projector at completion
      logs: {archiveUrl: s3://…, liveAvailable: true}
      artifacts: [{name: dist, sizeBytes: 812345, url: s3://…}]
```

**Who writes what (multi-writer discipline, enforced by SSA field managers):** controller owns `plan`, `phase`, pod orchestration fields; **gateway** owns per-job `Assigned/Running` transitions, `outputs`, `steps`, log/artifact pointers (server-side apply, field manager `crest-ci-gateway`, PATCH status subresource only). This is how gateway replicas stay stateless: the job's truth lives in the CR.

### 3.3 `RunnerJob` — the queue element (new)

The unit the gateway serves to runners. One per planned job, created by the controller when `needs` are satisfied:

```yaml
kind: RunnerJob
metadata: {name: run-<ulid>-j-<jobKey>, ownerReferences: [WorkflowRun], labels: {crest.dev/runs-on-hash: <h>, crest.dev/cluster: local, …}}
spec:
  runRef: {name: run-<ulid>}; jobKey: "test/m-3f9a2c"
  runsOn: ["self-hosted","linux","x64"]
  jobMessage: {secretRef: {name: jm-run-<ulid>-<jobKey>}}   # rendered protocol job message (§6.3), stored as Secret (contains injected secrets)
status:
  phase: Queued|Leased|Acquired|Completed|Abandoned
  leasedBy: "<runner-name>"; leaseExpiresAt: …; result: …
```

Rationale for a CRD here (vs D1's "no Runner CRD"): the *queue with lease semantics* needs optimistic-concurrency arbitration between active-active gateway replicas, and etcd `resourceVersion` CAS on a dedicated small object is exactly that. Runner **pods remain plain Pods** (D1 decision stands); `RunnerJob` is the assignment record, not the compute.

### 3.4 `RunnerPool` (new, minimal in v1)

Declares a warm/scaled pool per `runs-on` label set: `spec: {selectorLabels: ["self-hosted","linux","x64"], min: 0, max: 30, mode: k8s|dind, podTemplateRef}`. v1 semantics: `min: 0`, pure ephemeral scale-per-job (ARC scale-set behavior with min runners deferred to §8.5). Also the future multi-cluster capacity unit (§14).

### 3.5 Label schema — D1 §3.4 plus `crest.dev/runs-on-hash`, `crest.dev/cluster`, `crest.dev/call-path` (reusable-workflow ancestry for filtering). ULID names, ConfigMap event payloads, `definitionGeneration` pinning: unchanged.

---

## 4. Control Plane (`crest-ci-controller`)

Topology, libcluster, Lease election, warm-standby informer caches, deployment shape, RBAC: as D1 §4.1–4.3/§4.8, with these deltas:

- `Leader.Gate` children now: `WorkflowRunController`, `WorkflowDefinitionController`, `RunnerJobController` (lease-expiry/abandonment sweeper), `PodController` (pod↔RunnerJob health correlation), `Engine.Planner` (invoked inline by run reconciler, not a process), `GitHub.Bridge`, `TTL.Sweeper`, `Webhook.Ingest`.
- **Reconcile flow per WorkflowRun:** on create → run workflow engine (§5) → write `status.plan` → create `RunnerJob`s + job-message Secrets for root jobs → as gateway marks jobs complete, satisfy `needs`, render successor job messages (they need `needs.*.outputs`), create successor `RunnerJob`s → terminal aggregation → concurrency-group bookkeeping (§5.4).
- **Pod orchestration:** controller creates one ephemeral runner pod per `RunnerJob` at queue time (v1 scale-per-job; §8). Pod name = RunnerJob name.
- Webhook ingest, delivery idempotency, Checks bridge (§7 of D1, now sourced from `status.jobs` transitions), TTL sweeper: unchanged in mechanism.
- **BEAM role:** per-active-run `RunSession` processes (timers: job timeouts from `timeout-minutes`, matrix `fail-fast` cancellation fan-out, `max-parallel` gating) — reconstructible from status alone; SIGKILL×100 CI test retained.

---

## 5. Workflow Engine (new; the compatibility core)

Pure-Elixir library inside the controller (`CrestCI.Engine`), fully deterministic: `plan(definition, event, context) → DAG | error`, and `render_job_message(plan_job, contexts) → job message`. Determinism makes it property-testable and makes replans after failover byte-identical.

### 5.1 Parsing
Full workflow schema (every key in §3.1). Unknown keys → warnings surfaced on the check run, not failures (GitHub tolerates; we match). YAML anchors/merge keys honored.

### 5.2 Expressions (server-side scope)
Full `${{ }}` grammar: literals, operators (`==,!=,<,>,&&,||,!`, index/deref), functions `contains, startsWith, endsWith, format, join, toJSON, fromJSON, hashFiles*, always, success, failure, cancelled`. (*`hashFiles` and step-runtime functions evaluate on the **runner** — the runner binary carries its own evaluator for step-level expressions. Server-side scope = workflow/job level only: job `if`, `strategy`, `concurrency`, job `env`, reusable-workflow `with`/`secrets`, `runs-on`, `needs.*` references.*) Conformance: test vectors imported from `actions/languageservices` expressions package; divergence = release blocker.

### 5.3 Contexts
Assembled server-side per job: `github` (full event payload from ConfigMap + standard fields), `needs` (results + outputs), `strategy`/`matrix`, `vars`, `secrets`, `inputs` (workflow_call / workflow_dispatch), `env` (workflow→job merge; step-level merging is runner-side). `secrets`/`vars` resolved from K8s Secrets/ConfigMaps per repo/org (`crest-ci-secrets` ns, naming convention in contract pkg) with org→repo precedence matching GitHub.

### 5.4 Matrix, needs, concurrency
- Matrix: cross-product + `include`/`exclude` per GitHub's (subtle, well-documented) merge rules; job key `test/m-<hash(matrix-assignment)>`; `fail-fast` (default true) cancellation; `max-parallel` gating (RunSession-enforced).
- `needs`: DAG validation (cycles → Valid=False), `if: always()`-family semantics on failed dependencies.
- `concurrency`: group key rendered by engine → `spec.concurrencyKey`; controller keeps per-key state via a label-indexed cache scan: one Running run per key, `cancel-in-progress: true` sets `spec.cancelRequested` on the incumbent. Pending runs queue FIFO by ULID.

### 5.5 Reusable workflows (`workflow_call`)
- `jobs.<id>.uses: {owner}/{repo}/.github/workflows/{file}.yml@{ref}` and local `./.github/workflows/…` forms.
- Resolution: fetch via GitHub App `contents:read` (or configured git credential), **pin by resolved SHA**, cache the parsed definition as a `WorkflowDefinition` keyed by `(repo, path, sha)` — content-addressed, immutable, shared across runs.
- Inputs/secrets: typed input validation, `secrets: inherit` and explicit mapping; called-workflow `outputs` mapped to caller job outputs (feeding caller's `needs` context).
- Expansion: inlined into the caller's plan with `callPath` ancestry and job keys `caller/called-wf/inner-job`; GitHub's limits enforced (4 nesting levels, 20 unique reusable workflows per run) — configurable but defaulting to parity.
- Permissions: called workflow's `permissions` intersect caller's (parity), recorded in the plan for the future OIDC/token feature.

### 5.6 Compatibility Matrix & Phasing (exit criteria live in §13)

| Tier | Features | Target |
|---|---|---|
| C1 | `run` steps, `uses` actions (JS/Docker/composite), env/outputs/summaries, `needs`, artifacts v4, cache, `checkout` against real repos | M3 |
| C2 | matrix (full semantics), reusable workflows, concurrency, `container:` + `services:` via container-hooks, `workflow_dispatch`/`schedule` triggers | M5 |
| C3 | environments+approvals, OIDC tokens, `workflow_run` trigger, deployment statuses | v1.1 |

Compat scoreboard (§12.7) is a published artifact; "full compatibility" is claimed per-tier as suites go green, never hand-waved.

---

## 6. Runner Gateway (`crest-ci-gateway`)

### 6.1 Protocol posture
Implements the service endpoints the **pinned** runner version calls, derived from runner source (MIT — client code is the spec). Version pinning policy: gateway declares `SUPPORTED_RUNNER_VERSIONS`; the runner image (§8.1) is built from exactly those; upstream runner bumps are a normal PR that must pass the protocol conformance suite (§12.4). The gateway rejects unknown runner versions loudly rather than limping.

### 6.2 Runner lifecycle (JIT-only)
No PAT/registration-token flow in v1. Controller mints a **JIT config** per RunnerJob (we *are* the service, so we generate the same base64 bundle `--jitconfig` expects: runner identity, RSA credentials, server URL, labels, ephemeral flag) into the pod's env via Secret. Pod starts → `run.sh --jitconfig` → session create → message long-poll → receives exactly its one job → executes → completes → exits. Runner identity == pod name == RunnerJob name: the whole chain is greppable.

### 6.3 Job flow
1. Controller renders the **job message** (the protocol's job payload: steps in template form, contexts, endpoints+scoped tokens for Results/artifacts/cache/action-download, service/container specs) into a Secret at RunnerJob creation. Step-level expressions ship *unevaluated* — the runner's evaluator handles them (this is GitHub's own split, and it's why the engine's server-side scope (§5.2) is sufficient).
2. Runner long-polls its session queue on any gateway replica → replica leases the `RunnerJob` via CAS on `status` (`Queued→Leased`, `leaseExpiresAt = now+60s`) → delivers message → runner acks → `Acquired`.
3. During execution: timeline/step updates + log chunks (§7) with per-job scoped bearer tokens (Phoenix.Token; audience = job; TTL = job timeout).
4. Completion → gateway SSA-patches `WorkflowRun.status.jobs.<key>` (result, outputs, steps, pointers) and `RunnerJob → Completed`. Lease heartbeat lapse → `Abandoned` → controller retry policy.

### 6.4 Action download
The runner asks the service where to fetch each action. Gateway responds with URLs into its own **action tarball proxy/cache**: fetch-once from `codeload.github.com` (App credentials), content-address by `(repo, resolved-sha)`, store in S3, serve presigned. Buys: rate-limit immunity, air-gap path, and demo determinism.

### 6.5 Everything else the runner phones home for
Session heartbeats, `.runner` settings fetch, telemetry endpoints (accepted, dropped), auth renewals — enumerated exhaustively per pinned version by the conformance harness (§12.4), each either implemented or explicitly stubbed with a documented behavior. "Unknown call = 500 + alert" during bring-up; "unknown call = documented decision" at release.

### 6.6 Statelessness & scaling
Session and lease truth = CRs (+ short-lived token crypto via shared signing key Secret). Replica-local state = open long-poll sockets only. Runner reconnects land anywhere; log-chunk uploads idempotent by `(job, step, seq)`. HPA on open-connection count; each replica comfortably holds tens of thousands of parked long-polls (BEAM's home turf). Budget: 3 replicas @ 1 CPU/1.5 GiB ≈ 50 k parked runners (validated by §12.6 load suite before any such number is spoken aloud).

---

## 7. Logs, Artifacts, Cache (Results-compatible services, in the gateway)

### 7.1 Live logs
Runner uploads step-log lines in chunks → gateway appends to a per-job append-log in S3 (`…/live/<job>/<seq>.zst`, chunk index in Redis-free fashion: a tiny index object rewritten per N chunks + in-memory tail) **and** broadcasts on local PubSub for the relay.
### 7.2 Archives
On job completion the gateway compacts chunks → `s3://crest-ci-logs/<run>/<job>.ndjson.zst`, sets `archiveUrl`, deletes live chunks. D1's kubelet-follow and controller log-shipper are **deleted** — the runner protocol replaces both.
### 7.3 Artifacts v4 & cache
Artifacts: v4 flow (create → presigned multipart blob upload → finalize; list/download presigned) backed by `s3://crest-ci-artifacts/…`; retention per repo config. Cache: `actions/cache@v4`-compatible API (reserve/upload/commit + lookup with key/version/scope restore-key prefix semantics and branch-scoping rules matching GitHub) on `s3://crest-ci-cache/…`, LRU eviction by configurable budget. Both validated by running the real `upload-artifact@v4`/`cache@v4` actions in the compat corpus — the actions are the acceptance test.
### 7.4 Live-log relay (the sanctioned contract exception)
`GET /relay/runs/:run/jobs/:job/logs?from=<seq>` — SSE, resumable, read-only, dashboard-token auth. Dashboard tails it for in-flight jobs; archives for finished; gateway-down ⇒ archive-only degradation with a UI notice. This endpoint's shape lives in the contract package.

---

## 8. Runner Image & Pod Orchestration (ARC lineage)

### 8.1 Image
`FROM` a slim base; pinned `actions/runner` release tarball (checksummed) + `runner-container-hooks` k8s package + our 30-line entrypoint (assemble jitconfig from env, exec `run.sh`). Toolcache volume mount point per ARC convention. One image per runner version; tag = runner version.
### 8.2 Pod spec (ported from ARC conventions, attributed)
Ephemeral, `restartPolicy: Never`, `activeDeadlineSeconds` = job timeout + slack; `_work` emptyDir (sized), `ACTIONS_RUNNER_CONTAINER_HOOKS=…/k8s/index.js`, `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER` configurable; ServiceAccount `crest-runner` with the narrow pod-create RBAC container-hooks needs (create/watch pods+exec in `crest-ci-runners` only); non-root, seccomp RuntimeDefault; resources from `RunnerPool.podTemplateRef` (laptop defaults tiny per §10).
### 8.3 Modes
`k8s` (default: container jobs/services as sibling pods via hooks — quota-friendly, no privileged) and `dind` (opt-in per pool for docker-dependent workflows; documented risk). Matrix mirrors ARC's.
### 8.4 Scheduling v1
Scale-per-job: RunnerJob created ⇒ pod created (deterministic name). Quota denial = backpressure (Pending + requeue) exactly as D1.
### 8.5 Warm pools (v1.1, designed-for)
`RunnerPool.min > 0` ⇒ idle runners parked in long-poll **without** a RunnerJob; gateway matches queued jobs to parked runners by label set (lease CAS unchanged); controller replenishes. ARC's scale-set semantics are the reference. Nothing in v1's flow precludes this — the queue already doesn't care whether the pod pre-existed.

---

## 9. Dashboard — deltas from D1

Informer contract, ETS layout/indexes, LiveView streams + cursor pagination + 150 ms render batching, JSON API + RunsChannel, auth posture, deployment: **unchanged from D1 §5**. Changes:
- Log pane sources from the relay (§7.4) with archive fallback; kubelet-follow code path removed; per-replica concurrent-tail cap retained.
- New informers: `RunnerJob`, `RunnerPool` (queue-depth and pool views).
- Run detail renders the expanded plan DAG (matrix groups collapsed, reusable-workflow ancestry as breadcrumbs from `callPath`).
- `/fleet` adds gateway metrics (parked long-polls, lease CAS conflict rate, chunk ingest rate).

## 10. Local Development & k3s — deltas from D1

Toolchain, k3d bootstrap (memory-capped cluster + registry), ResourceQuota/LimitRange laptop guards, three run modes (`dev-mock`, `dev-k3d`, `dev-hybrid`), image loop: **unchanged from D1 §10** with these additions:
- `dev-hybrid` note: runners in k3d dial the gateway on the host — `just dev-hybrid` templates the gateway URL as `host.k3d.internal:4001` into JIT configs. This preserves the best loop (apps under `iex`, real runner pods in-cluster).
- Real-runner laptop profile: runner pods `requests 100m/256Mi, limits 500m/768Mi` (the official runner + node is heavier than D1's toy runner), quota `pods: 20`, so worst-case runner burst ≈ 5 GiB, still inside D1's 16 GB envelope (recomputed table in repo `docs/budgets.md`).
- `just fixtures` clones a pinned set of public fixture repos into a local Gitea container (air-gapped `checkout` targets + reusable-workflow cross-repo fixtures), so the compat corpus runs without touching github.com.

## 11. Resource Budgets — deltas from D1

D1 §11 stands (retention as the memory lever, TTL sweeper, ETS caps, BEAM cgroup flags, backpressure map) plus: S3 budgets per bucket (logs/artifacts/cache) with lifecycle rules; cache LRU budget default 5 GiB laptop / 50 GiB prod; gateway connection budget with `max_connections` shed-with-Retry-After; job-message Secrets TTL-swept with their RunnerJob.

---

## 12. Testing Strategy (revised — compatibility is now the headline suite)

Layers from D1 (unit, property, integration-vs-mock, conformance mock↔k3d, chaos, load, extension Playwright) all stand. New/changed:

### 12.4 Runner-protocol conformance suite ★
- **Golden-transcript harness:** run the real pinned runner binary (in a container, no k8s) against the gateway with a scripted trivial job; record every HTTP exchange; assert against golden transcripts checked into the repo. Any gateway change or runner-version bump re-records under review.
- **SimRunner fidelity check:** SimRunner (below) replays the same scenario; its transcript must match the real runner's on all protocol-relevant fields — this is what licenses SimRunner-based load numbers.
- Fault matrix: kill gateway mid-poll / mid-chunk / mid-acquire ×N; assert lease CAS grants exactly one acquisition, chunk idempotency, session resume on another replica.

### 12.5 Compatibility corpus ★ (the "full compatibility" proof)
`compat/` = one fixture repo per feature: real `actions/checkout@v4` (against local Gitea + against github.com in the weekly job), `setup-*` toolchain actions, composite + JS + Docker actions, matrix incl. include/exclude edge cases (ported from GitHub docs examples), reusable workflows (nesting ×4, `secrets: inherit`, outputs), `container:` + `services:` (postgres healthcheck pattern), artifacts v4 round-trip, cache hit/miss/restore-keys, concurrency cancel-in-progress, `fail-fast` behavior, step summaries/outputs/env files, `continue-on-error`, timeouts. Each fixture = workflow + expected outcome assertion (job results, artifact contents, log substrings). Runs nightly on k3d; **the scoreboard (per-fixture pass/fail, published artifact) is the compat claim.** Expressions engine additionally runs the imported `actions/languageservices` vector suite on every commit.

### 12.6 Load & scale — SimRunner
SimRunner = lightweight Elixir client speaking the **real gateway protocol** (session, long-poll, acquire, timeline, chunked logs) with simulated step timing — process-per-runner in mock-k8s. Demo/load numbers therefore exercise engine → queue → gateway → Results end-to-end; only containers are fake, and the demo slide says exactly that. Mock-k8s (store/watch/RV/pagination semantics, chaos endpoints, profile budgets & self-refusal) unchanged from D1; pod-lifecycle simulation shrinks to pod-object bookkeeping since SimRunner replaces fake log generation. Nightly `demo-small` assertions extended: p99 queue→acquire < 500 ms at 25 jobs/s; lease-conflict rate < 2 %; zero double-acquisitions ever (hard gate).

### 12.7 Failover-under-execution ★
The G1 test that matters now: 500 SimRunner jobs in flight → kill controller leader → assert zero job interruption (gateway path unaffected), scheduling gap ≤ 20 s, no duplicate RunnerJobs. Then: rolling-restart all gateway replicas mid-flight → assert every job's logs complete and gapless (chunk idempotency proof), all jobs reach exactly-one terminal state.

---

## 13. Milestones (revised)

| M | Deliverable | Exit criterion |
|---|---|---|
| M0 | Contract + CRDs (incl. RunnerJob/RunnerPool) + mock-k8s core | conformance green vs mock; kubectl basic ops |
| M1 | Controller skeleton: election, run reconciler (no engine — hand-planned fixture), RunnerJob queue + lease CAS | failover chaos green; queue property tests green |
| M2 | **Gateway v0 + real runner runs one `run:`-only job end-to-end on k3d** (golden transcripts recorded) | `echo hello` from the official runner binary through our whole stack |
| M3 | Results services (logs/artifacts/cache) + action-dl proxy + engine C1 | **Tier C1 corpus green**; real `checkout`+`cache`+`upload-artifact` pass |
| M4 | Engine C2: matrix, reusable workflows, concurrency; container-hooks k8s mode | **Tier C2 corpus green** |
| M5 | Dashboard deltas (relay logs, DAG view, queue views) + Checks bridge + real-repo smee demo | check runs on a real PR; live logs in dashboard |
| M6 | SimRunner + profiles + `/fleet` + chaos endpoints | `demo-small` nightly green incl. §12.6 gates |
| M7 | Extension + demo runbook + `demo-large` on demo box | 50 k concurrent SimRunner jobs; §12.7 failover-under-load clean |

## 14. Multi-Cluster Scheduling (designed-for; build later)

Already paid for in v1: `spec.placement.cluster` on runs, `crest.dev/cluster` labels on RunnerJob/RunnerPool, outbound-only runner connectivity (runners anywhere can reach the gateway), and a `ClusterCredential`-shaped config slot in the controller's conn builder. The later work, isolated to the controller: a `Scheduler` Gate child that binds runs→clusters by RunnerPool capacity/labels (kube-scheduler-style score+bind, trivial v1 impl = static "local"); per-cluster K8s clients + per-cluster pod informers; quota-denial backpressure becomes a scheduling signal. Gateway and dashboard need **zero** changes except a cluster filter chip — which is the payoff of the outbound-runner architecture and why this is an extension, not a rewrite.

## Appendix A — Repo conventions: unchanged from D1 (+ NOTICE files per §1.5).
## Appendix B — Decision log (revised)
- Reimplement job execution (act-style) → **rejected**: run official runner, implement the service (compat by construction; §1.1).
- PAT/registration-token runner enrollment → rejected: JIT-only (we mint it; simpler, ephemeral-native).
- Kubelet log follow (D1) → deleted: runner protocol carries logs; relay endpoint is the sanctioned contract exception.
- Runner CRD for compute → still rejected (plain Pods); RunnerJob CRD adopted for **queue arbitration only** (CAS leasing between active-active gateways).
- ARC-as-client (implement the scale-set listener protocol + GHES facade so unmodified ARC manages pods against our service) → **evaluated and rejected for v1**. Decisive asymmetry vs. the runner bet: we ship the runner binary (pinned, bump on our schedule), but users ship ARC (Helm-installed, auto-upgrading, internal protocol with both ends controlled by GitHub and a history of breaking between ARC minors). Facade surface is also larger than the queue: admin-token exchange, scale-set CRUD under `_apis/runtime`, listener sessions with a distinct message schema, statistics-driven scaling — all supporting a third-party client binary across a version matrix. Our own pod orchestration is ~400 lines inside reconciler infrastructure that exists anyway and advances no fewer goals. Revisit post-v1 solely as an adoption adapter for existing ARC installs, fronting the RunnerJob queue (§3.3), behind its own pinned supported-ARC-versions policy.
- Gateway inside controller → rejected: opposite scaling/availability profiles (§1.4).
- Horde/`:global` election, Mnesia, controller↔dashboard RPC, minikube/kind, full-takeover extension → rejected as in D1.
