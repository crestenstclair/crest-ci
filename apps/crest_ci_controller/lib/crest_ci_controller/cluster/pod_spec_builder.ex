defmodule CrestCiController.Cluster.PodSpecBuilder do
  @moduledoc """
  Pure domain service: `(RunnerJob wire object, image, gateway_url,
  namespace, service_account, active_deadline_seconds, resource profile)
  -> RunnerPodSpec`.

  This module never touches a cluster and never derives a name of its
  own — the pod name is simply the given `RunnerJob`'s own
  `metadata.name`, which is already the deterministic child-object name
  `CrestCiContract.DeterministicNaming` derived for it (run ULID + job
  key) back when the `RunnerJob` itself was created. Reusing that same
  name for the pod (rather than re-deriving it here) is what keeps a
  409 `AlreadyExists` on `create` a safe replay no-op after a failover
  re-reconcile: the same `RunnerJob` always yields the same pod name,
  with zero extra state for this module to hold.

  `labels` are copied verbatim from the `RunnerJob`'s own
  `metadata.labels` — the same `runs-on` placement selectors the
  gateway used to route the job are what the real Kubernetes scheduler
  needs to place the pod consistently.

  `env` always carries the runner's gateway/identity claim, purely
  derived from the given inputs (no I/O, no randomness): `GATEWAY_URL`
  / `GATEWAY_URLS` (the gateway endpoint the runner dials outbound),
  `CREST_CI_RUNNER_NAME` / `RUNNER_NAME` / `RUNNER_ID` (the runner's own
  identity claim), `RUNNER_JIT_CONFIG` (a JSON identity/JIT bundle the
  entrypoint reads to authenticate its first gateway session), and
  `DEMO` / `DEMO_HEADLESS` flags (off by default; overridable via the
  `:demo` / `:demo_headless` fields for the mock-cluster demo harness).
  Credentials never appear here: this env carries only identity claims
  and the gateway URL, never kubeconfig secrets — those stay in the
  controller's own `KubeClient` conn (see
  `CrestCiController.Cluster.ClusterConnBuilder`).

  Ephemeral by construction: `RunnerPodSpec` carries no `restartPolicy`
  field itself (see its own moduledoc) — `active_deadline_seconds`
  (already computed by the caller as job timeout + slack) is this
  module's half of the ephemeral contract; `restartPolicy: "Never"` and
  the pod's `ownerReference` back to the `RunnerJob` are the real `Pod`
  object's concern, added by
  `CrestCiController.Cluster.RealPodOrchestrator`, not here.

  Pure and deterministic: the same `fields` map always builds a
  byte-identical `RunnerPodSpec` — there is no hidden clock, counter, or
  random seed anywhere in this module.
  """

  alias CrestCiController.Cluster.RunnerPodSpec

  @type fields :: %{
          required(:runner_job) => map(),
          required(:image) => String.t(),
          required(:gateway_url) => String.t(),
          required(:namespace) => String.t(),
          required(:service_account) => String.t(),
          required(:active_deadline_seconds) => pos_integer(),
          optional(:profile) => map(),
          optional(:cpu_request) => String.t(),
          optional(:cpu_limit) => String.t(),
          optional(:mem_request) => String.t(),
          optional(:mem_limit) => String.t(),
          optional(:demo) => boolean(),
          optional(:demo_headless) => boolean()
        }

  @profile_keys [:cpu_request, :cpu_limit, :mem_request, :mem_limit]

  @doc """
  Builds a `RunnerPodSpec` for one `RunnerJob`.

  `fields` (atom keys):

    * `:runner_job` — the decoded `RunnerJob` wire object (the one this
      pod belongs to). Its `metadata.name` becomes the pod name,
      `metadata.labels` are copied verbatim, and `metadata.uid` /
      `spec.jobKey` / `spec.runRef` (when present) feed the identity
      env — required.
    * `:image`, `:gateway_url`, `:namespace`, `:service_account`,
      `:active_deadline_seconds` — required, passed straight to
      `RunnerPodSpec.new/1`.
    * `:profile` — optional map of `RunnerPodSpec.new/1`'s resource
      keys (`cpu_request`, `cpu_limit`, `mem_request`, `mem_limit`) to
      override the laptop-profile defaults; the same keys may also be
      given flat at the top level of `fields` (a `:profile` entry wins
      over a flat one of the same name).
    * `:demo`, `:demo_headless` — optional booleans (default `false`)
      controlling the `DEMO` / `DEMO_HEADLESS` env flags.

  Returns `{:ok, RunnerPodSpec.t()} | {:error, reason}` — any invalid
  field is reported by `RunnerPodSpec.new/1` itself (a missing/invalid
  `RunnerJob` name is reported here, before ever reaching it).
  """
  @spec build(fields()) :: {:ok, RunnerPodSpec.t()} | {:error, term()}
  def build(fields) when is_map(fields) do
    with {:ok, runner_job} <- fetch_runner_job(fields),
         {:ok, name} <- fetch_pod_name(runner_job) do
      RunnerPodSpec.new(
        Map.merge(resource_profile(fields), %{
          name: name,
          namespace: Map.get(fields, :namespace),
          image: Map.get(fields, :image),
          service_account: Map.get(fields, :service_account),
          active_deadline_seconds: Map.get(fields, :active_deadline_seconds),
          labels: runner_job_labels(runner_job),
          env: build_env(fields, runner_job, name)
        })
      )
    end
  end

  defp fetch_runner_job(%{runner_job: %{} = runner_job}), do: {:ok, runner_job}
  defp fetch_runner_job(fields), do: {:error, {:invalid_runner_job, Map.get(fields, :runner_job)}}

  defp fetch_pod_name(runner_job) do
    case get_in(runner_job, ["metadata", "name"]) do
      name when is_binary(name) and byte_size(name) > 0 -> {:ok, name}
      other -> {:error, {:invalid_runner_job_name, other}}
    end
  end

  defp runner_job_labels(runner_job), do: get_in(runner_job, ["metadata", "labels"]) || %{}

  defp resource_profile(fields) do
    fields
    |> Map.take(@profile_keys)
    |> Map.merge(Map.get(fields, :profile, %{}))
  end

  # -- env: purely derived from the given inputs, no I/O, no randomness --

  defp build_env(fields, runner_job, name) do
    gateway_url = Map.get(fields, :gateway_url)
    run_id = get_in(runner_job, ["metadata", "uid"]) || name
    job_key = get_in(runner_job, ["spec", "jobKey"]) || ""
    run_ref = get_in(runner_job, ["spec", "runRef"]) || ""

    %{
      "GATEWAY_URL" => gateway_url,
      "GATEWAY_URLS" => gateway_url,
      "CREST_CI_RUNNER_NAME" => name,
      "RUNNER_NAME" => name,
      "RUNNER_ID" => run_id,
      "RUNNER_JIT_CONFIG" => jit_config(name, run_id, job_key, run_ref),
      "DEMO" => flag(Map.get(fields, :demo, false)),
      "DEMO_HEADLESS" => flag(Map.get(fields, :demo_headless, false))
    }
  end

  defp jit_config(name, run_id, job_key, run_ref) do
    Jason.encode!(%{
      "runnerName" => name,
      "runnerId" => run_id,
      "jobKey" => job_key,
      "runRef" => run_ref
    })
  end

  defp flag(true), do: "1"
  defp flag(false), do: "0"
end
