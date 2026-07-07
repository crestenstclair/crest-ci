.PHONY: setup fmt check test conformance chaos props results engine cluster-unit demo-e2e demo-results demo-engine demo-scene demo-scene-check demo-k3d k3d-up k3d-load k3d-down k3d-status

.DEFAULT_GOAL := test

setup:
	mix deps.get

fmt:
	mix format

check:
	@output=$$(mix compile --warnings-as-errors 2>&1); status=$$?; \
	echo "$$output" | grep -v 'xref: \[exclude: \.\.\.\]' | grep -v 'xref_exclude_opts'; \
	exit $$status

test:
	mix test

conformance:
	cd apps/mock_k8s && mix test

chaos:
	cd apps/crest_ci_controller && mix test --only chaos

props:
	cd apps/crest_ci_gateway && mix test --only property

results:
	cd apps/crest_ci_gateway && mix test test/results

engine:
	cd apps/crest_ci_controller && mix test test/engine

cluster-unit:
	cd apps/crest_ci_controller && mix test test/cluster && cd ../.. && cd apps/sim_runner && mix test test/cluster

demo-e2e:
	mix crest_ci.demo_e2e

demo-results:
	@output=$$(mix crest_ci.demo_results 2>&1); status=$$?; \
	echo "$$output"; \
	run_count=$$(echo "$$output" | grep -oE 'runs_succeeded=[0-9]+' | head -1 | cut -d= -f2); \
	if [ -n "$$run_count" ]; then echo "run_count=$$run_count"; fi; \
	exit $$status

demo-engine:
	mix crest_ci.demo_engine

demo-scene:
	mix crest_ci.demo_scene

demo-scene-check:
	DEMO_DURATION=25 DEMO_HEADLESS=1 mix crest_ci.demo_scene

# -- Real k3d cluster lifecycle (MANUAL, out-of-gate) -----------------------
#
# None of these targets are a prerequisite of test/check/demo-e2e, and none
# of test/check/demo-e2e's recipes invoke them — the mix gate always runs
# against the in-repo mock Kubernetes API server (see deploy/k3d/cluster.yaml
# and deploy/runner/Dockerfile for why).

k3d-up:
	k3d cluster create --config deploy/k3d/cluster.yaml
	kubectl apply -f deploy/crds
	kubectl apply -f deploy/k8s

k3d-load:
	docker build -f deploy/runner/Dockerfile --build-arg SIM_RUNNER_SRC=apps/sim_runner -t crest-ci/runner:dev .
	k3d image import crest-ci/runner:dev --cluster crest-ci

k3d-down:
	k3d cluster delete crest-ci

k3d-status:
	kubectl get nodes
	kubectl get pods -A

# MANUAL, out-of-gate: talks to a real k3d cluster (see make k3d-up). Never a
# prerequisite of test/check/demo-e2e, and never invoked from their recipes.
demo-k3d:
	@kubectl cluster-info >/dev/null 2>&1 || { \
		echo "no reachable Kubernetes cluster (KUBECONFIG=$${KUBECONFIG:-~/.kube/config}); run 'make k3d-up' first" >&2; \
		exit 1; \
	}
	mix crest_ci.demo_k3d
