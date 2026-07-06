defmodule CrestCiContract.DeterministicNaming do
  @moduledoc """
  `DeterministicNaming` derives Kubernetes-object names for the child
  resources of a `WorkflowRun`: the `RunnerJob` and the pod that ultimately
  executes a job.

  Names are derived purely from the run's `Ulid` and the job's `JobKey` —
  identical inputs always yield an identical output string. This is what
  lets a failover controller re-reconcile the same run without ever
  producing duplicate children: a `create` for a name that already exists
  comes back `{:error, :already_exists}`, which the reconciler treats as a
  successful no-op rather than retrying under a fresh name.

  Pattern: `"run-<ulid>-j-<slugged jobKey>"`, where the job-key fragment is
  slugged via `CrestCiContract.JobKey.slug/1` (lowercased, `/` replaced by
  `-`, restricted to `[a-z0-9-]`) so the result is always a legal
  Kubernetes resource name.
  """

  alias CrestCiContract.JobKey
  alias CrestCiContract.Ulid

  @doc """
  Derive the deterministic `RunnerJob` name for a run `ulid` and `job_key`.

  Pure and deterministic: the same `(ulid, job_key)` pair always produces
  the same string, across processes and across restarts.
  """
  @spec runner_job_name(Ulid.t(), JobKey.t()) :: String.t()
  def runner_job_name(ulid, job_key) when is_binary(ulid) and is_binary(job_key) do
    "run-" <> ulid <> "-j-" <> JobKey.slug(job_key)
  end

  @doc """
  Derive the deterministic pod name for a run `ulid` and `job_key`.

  Shares the same name pattern as `runner_job_name/2` — the pod that
  executes a `RunnerJob` is named identically to it, so the two resources
  are trivially correlatable by name alone.
  """
  @spec pod_name(Ulid.t(), JobKey.t()) :: String.t()
  def pod_name(ulid, job_key) when is_binary(ulid) and is_binary(job_key) do
    runner_job_name(ulid, job_key)
  end
end
