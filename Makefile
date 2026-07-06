.PHONY: setup fmt check test conformance chaos props results engine demo-e2e demo-results demo-engine demo-scene demo-scene-check

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
