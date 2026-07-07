#!/bin/sh
# deploy/runner/entrypoint.sh
#
# The runner Pod's single command: read GATEWAY_URLS and the JIT identity
# bundle from env (the same env PodSpecBuilder injects into the Pod spec
# it renders for a RunnerJob), start exactly one RunnerClient, run its one
# job to completion, and exit. The Pod's restartPolicy is Never — this
# container runs once, mirroring the official actions/runner's
# `run.sh --jitconfig` shape for our SimRunner client.
set -eu

: "${GATEWAY_URLS:?GATEWAY_URLS is required: a comma-separated list of gateway base URLs (e.g. http://crest-ci-gateway:8080,http://crest-ci-gateway-2:8080)}"
: "${RUNNER_JIT_CONFIG:?RUNNER_JIT_CONFIG is required: the JSON-encoded JIT identity bundle the gateway issued for this run's job}"

# Optional identifying labels — logged only, never required to start.
: "${RUNNER_NAME:=}"
: "${RUNNER_ID:=}"

echo "entrypoint: starting runner name=${RUNNER_NAME} id=${RUNNER_ID}"

exec /app/bin/sim_runner eval '
  gateway_urls =
    System.fetch_env!("GATEWAY_URLS")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  jit_config =
    System.fetch_env!("RUNNER_JIT_CONFIG")
    |> Jason.decode!()

  {:ok, pid} = SimRunner.RunnerClient.start(gateway_urls, jit_config)
  ref = Process.monitor(pid)

  receive do
    {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
  end
'
