# syntax=docker/dockerfile:1.7
#
# deploy/runner/Dockerfile — packages the SimRunner client (apps/sim_runner)
# as an ephemeral, single-job runner image. Build context is the umbrella
# root (SimRunner depends on the in-umbrella crest_ci_contract app):
#
#   docker build -f deploy/runner/Dockerfile \
#     --build-arg SIM_RUNNER_SRC=apps/sim_runner \
#     -t crest-ci/runner:dev .
#
# `make k3d-load` (deploy/k3d, out-of-gate/manual) drives this build and
# imports the resulting image into the k3d cluster's registry. This
# Dockerfile is never invoked by the mix gate — `make cluster-unit` only
# runs the structural text check in runner_image_test.exs, never `docker
# build`.

ARG ELIXIR_BASE=hexpm/elixir:1.20.0-erlang-29.0-alpine-3.20.0

FROM ${ELIXIR_BASE} AS builder

# Path (relative to the umbrella root build context) of the app this image
# packages — lets `make k3d-load` point the same Dockerfile at a renamed or
# relocated sim_runner app without editing this file.
ARG SIM_RUNNER_SRC=apps/sim_runner

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /build

RUN apk add --no-cache build-base git

RUN mix local.hex --force && mix local.rebar --force

# Umbrella-wide manifest first so `deps.get`/compile layers cache across
# unrelated app source changes.
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps ./apps

RUN mix deps.get --only prod
RUN mix compile --warnings-as-errors

# Release only the one app this image ships — the ephemeral runner needs
# SimRunner.RunnerClient, not the controller or gateway apps.
RUN mix release sim_runner --path /build/release

FROM ${ELIXIR_BASE} AS runtime

# Non-root: no runner process ever needs root inside the Pod, and the JIT
# identity bundle / session tokens passed via env must never touch a
# root-owned process.
RUN addgroup -S runner && adduser -S runner -G runner -h /home/runner

WORKDIR /app

COPY --from=builder --chown=runner:runner /build/release ./
COPY --chown=runner:runner deploy/runner/entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh

USER runner

# Populated at Pod-create time by the controller's PodSpecBuilder — never
# baked into the image. Declared here only to document the contract;
# empty defaults mean "must be supplied by the Pod spec" and the
# entrypoint fails fast if they are missing.
ENV GATEWAY_URLS="" \
    RUNNER_JIT_CONFIG="" \
    RUNNER_NAME="" \
    RUNNER_ID=""

ENTRYPOINT ["/app/entrypoint.sh"]
