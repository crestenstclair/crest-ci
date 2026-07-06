.PHONY: setup fmt check test conformance chaos props results demo-e2e demo-results

.DEFAULT_GOAL := test

setup:
	mix deps.get

fmt:
	mix format

check:
	mix compile --warnings-as-errors

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

demo-e2e:
	mix crest_ci.demo_e2e

demo-results:
	mix crest_ci.demo_results
