package crestci

// Project manifests — the umbrella skeleton and the human entry points.
// Crate/package facts (dependency pins, app layout) live HERE and nowhere else.

project: assets: UmbrellaManifest: {
	kind:        "mix-manifest"
	description: "the umbrella root mix.exs, shared config, and one mix.exs per app"
	prompts: [
		"Files: mix.exs (umbrella root), config/config.exs, .formatter.exs (root, covering all apps), and one mix.exs + .formatter.exs per app under apps/.",
		"Elixir umbrella project named :crest_ci, elixir '~> 1.20', apps_path: 'apps'. Five apps:",
		"apps/crest_ci_contract — the shared CRD struct/schema package. Deps: {:jason, \"~> 1.4\"}.",
		"apps/mock_k8s — in-memory Kubernetes API server. Deps: {:plug, \"~> 1.16\"}, {:bandit, \"~> 1.5\"}, {:jason, \"~> 1.4\"}, {:crest_ci_contract, in_umbrella: true}.",
		"apps/crest_ci_controller — leader-elected control plane. Deps: {:req, \"~> 0.5\"}, {:jason, \"~> 1.4\"}, {:yaml_elixir, \"~> 2.11\"}, {:crest_ci_contract, in_umbrella: true}, {:stream_data, \"~> 1.1\", only: [:test, :dev]}. Test env also depends on {:mock_k8s, in_umbrella: true} and {:crest_ci_gateway, in_umbrella: true} and {:sim_runner, in_umbrella: true} so cross-component suites (chaos, e2e) can boot the whole system.",
		"apps/crest_ci_gateway — active-active runner gateway. Deps: {:plug, \"~> 1.16\"}, {:bandit, \"~> 1.5\"}, {:req, \"~> 0.5\"}, {:jason, \"~> 1.4\"}, {:crest_ci_contract, in_umbrella: true}, {:stream_data, \"~> 1.1\", only: [:test, :dev]}, and test-only in_umbrella deps on mock_k8s and sim_runner.",
		"apps/sim_runner — protocol-real simulated runner client. Deps: {:req, \"~> 0.5\"}, {:jason, \"~> 1.4\"}, {:crest_ci_contract, in_umbrella: true}.",
		"No app starts network listeners automatically from config — mock_k8s, controller, and gateway expose start_link/start functions that tests and the demo task call explicitly with ports/options. Each app's Application module may supervise internal registries but must not bind ports at boot.",
		"config/config.exs is minimal: logger level per Mix.env (warning in test), no environment-coupled endpoints.",
	]
	validations: [
		{kind: "custom", command: ["mix", "deps.get"], description: "dependency resolution succeeds"},
	]
}

project: assets: ProjectMakefile: {
	kind:        "makefile"
	description: "Makefile — the human entry points for building, testing, and demoing"
	uses: ["asset.UmbrellaManifest"]
	prompts: [
		"File path: Makefile",
		"Targets: `setup` (mix deps.get), `fmt` (mix format), `check` (mix compile --warnings-as-errors), `test` (mix test), `conformance` (cd apps/mock_k8s && mix test), `chaos` (cd apps/crest_ci_controller && mix test --only chaos), `props` (cd apps/crest_ci_gateway && mix test --only property), `results` (cd apps/crest_ci_gateway && mix test test/results), `engine` (cd apps/crest_ci_controller && mix test test/engine), `cluster-unit` (cd apps/crest_ci_controller && mix test test/cluster && cd ../.. && cd apps/sim_runner && mix test test/cluster — the mix-only cluster checks; NEVER touches Docker), `demo-e2e` (mix crest_ci.demo_e2e — boots the full in-BEAM system and prints measured results), `demo-results` (mix crest_ci.demo_results — two runs with artifacts + cache across the full stack), `demo-engine` (mix crest_ci.demo_engine — a real workflow YAML planned by the engine and executed end-to-end), `demo-scene` (mix crest_ci.demo_scene — the live narrated demo with ANSI dashboard and scripted chaos; the flagship watchable target), `demo-scene-check` (DEMO_DURATION=25 DEMO_HEADLESS=1 mix crest_ci.demo_scene — the short headless variant the gate runs).",
		"Every target is phony; default target is `test`.",
	]
	validations: [
		{kind: "integration", command: ["make", "check"], description: "make check compiles the umbrella", assertions: [
			{kind: "exit_code", expected: 0},
		]},
	]
}
