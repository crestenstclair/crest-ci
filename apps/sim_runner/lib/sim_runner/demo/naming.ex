defmodule SimRunner.Demo.Naming do
  @moduledoc """
  Deterministic child naming for the E2E demo harness — mirrors
  `domainService.Contract.DeterministicNaming` (not yet generated in this
  session's wave order): "the RunnerJob and pod for run `<ulid>` job
  `<jobKey>` is `run-<ulid>-j-<slugged jobKey>`". Reuses the real
  `CrestCiContract.JobKey.slug/1` for the slugging rule itself, so only
  the naming template is duplicated here, never the slugging logic.

  Pure functions: identical input always yields identical output, which
  is what makes a reconcile pass's `create` calls naturally idempotent — a
  409 `AlreadyExists` on the same deterministic name during a replay is a
  no-op, never a duplicate.
  """

  alias CrestCiContract.JobKey

  @doc "The `WorkflowRun` object name for a demo run identified by `run_ulid`."
  @spec run_name(String.t()) :: String.t()
  def run_name(run_ulid) when is_binary(run_ulid), do: "run-#{run_ulid}"

  @doc "The deterministic RunnerJob/Pod name for `job_key` under `run_ulid`."
  @spec child_name(String.t(), JobKey.t()) :: String.t()
  def child_name(run_ulid, job_key) when is_binary(run_ulid) and is_binary(job_key) do
    "run-#{run_ulid}-j-#{JobKey.slug(job_key)}"
  end
end
