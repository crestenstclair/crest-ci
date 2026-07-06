defmodule CrestCiGateway.LeaseArbiter do
  @moduledoc """
  `domainService.Gateway.LeaseArbiter` — leases a `Queued` `RunnerJob` to a
  polling runner, and confirms acquisition once the runner acks the lease.

  A `RunnerJob` is acquired by exactly one runner, ever. This module is
  *not* the arbiter in the sense of holding a lock: it never keeps any
  in-process record of who has what. The sole arbitration mechanism is the
  `resourceVersion` compare-and-swap `port.Contract.KubeClient.patch_status/6`
  already gives every caller — several active-active gateway replicas (or
  several concurrent callers on the same replica) racing `lease/4` against
  the same `RunnerJob` all read the same `Queued` status, but only the
  first `patch_status/6` to land keeps its expected `resourceVersion`; every
  later one arrives against a resourceVersion that has already moved and
  comes back `{:error, :conflict}`. This module translates a lost CAS to
  `{:error, :lost}` — the caller (a losing gateway replica) simply moves on
  and the runner it was serving re-polls, per the "loser moves on" rule.
  There is no retry-and-steal here: retrying a lost race would mean forcing
  a write over a status some other actor already owns, which is exactly
  what optimistic concurrency exists to forbid.

  Legal phase transitions are delegated to
  `CrestCiContract.RunnerJobStatus.legal_transition?/2` rather than
  re-encoded here: `lease/4` only ever attempts the `Queued -> Leased`
  transition and `confirm_acquisition/3` only ever attempts
  `Leased -> Acquired`. Any `RunnerJob` observed in any other phase is
  reported as `{:error, :lost}` without even attempting a write — a runner
  cannot lease a job that is already `Leased`/`Acquired`/`Completed`, and it
  cannot confirm acquisition of a job it never held the lease on. This
  keeps the gateway from ever silently moving a `RunnerJob` backward (e.g.
  an expired lease back to `Queued`) — that transition belongs solely to
  the controller sweeper (`CrestCiController.LeaseSweeper`), never to this
  module.

  `confirm_acquisition/3` additionally requires the caller's `leased_by`
  identity to match the `leasedBy` already recorded on the status: a
  runner confirming acquisition of a lease it does not hold is exactly as
  much a loser as a runner that lost the original `lease/4` race.

  This module holds no state of its own — every call is a fresh
  read-decide-CAS-write cycle against the resource store, so it converges
  correctly no matter which gateway replica (or how many concurrently)
  call it, and survives any replica being killed and restarted mid-race:
  a crash before the CAS lands is indistinguishable from never having
  raced at all.

  ## `conn`

  Per `port.Contract.KubeClient`, `conn` is `{client_module, raw_conn}`:
  `client_module` is any module implementing `CrestCiContract.KubeClient`,
  and `raw_conn` is that module's own opaque connection handle. Bundling
  the two together (the same `kube_conn` shape
  `CrestCiController.LeaseSweeper` and `CrestCiGateway.RunnerProtocolHttp`
  use) is what lets every function here stay adapter-agnostic — callers
  inject whichever `KubeClient` adapter they want (a real HTTP-based one in
  production, an in-memory fake in tests) without this module ever
  constructing or knowing about a concrete adapter itself (Dependency
  Inversion).
  """

  alias CrestCiContract.RunnerJobStatus

  @typedoc "A `CrestCiContract.KubeClient`-implementing module paired with its own opaque conn."
  @type conn :: {module(), term()}

  @type runner_job_name :: String.t()
  @type leased_by :: String.t()
  @type lease_duration_seconds :: non_neg_integer()

  @gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  @doc """
  Lease the `Queued` `RunnerJob` named `runner_job_name` to `leased_by` for
  `lease_duration_seconds`.

  Reads the current status, and — only when the current phase legally
  transitions to `:leased` (i.e. the job is currently `Queued`) — attempts
  a `patch_status/6` CAS against the `resourceVersion` just read, setting
  `leasedBy` and a `leaseExpiresAt` `lease_duration_seconds` seconds from
  now.

  Returns:

    * `{:ok, :leased}` — this call won the race; the `RunnerJob` status
      now shows `leasedBy` == `leased_by`.
    * `{:error, :lost}` — either the job was not `Queued` when read, or it
      was `Queued` but another actor's CAS landed first (a stale
      `resourceVersion` write is never forced, per the optimistic
      concurrency invariant). The caller simply moves on.
    * `{:error, term()}` — any other `KubeClient` or decoding failure
      (e.g. `{:error, :not_found}` when no such `RunnerJob` exists).
  """
  @spec lease(conn(), runner_job_name(), leased_by(), lease_duration_seconds()) ::
          {:ok, :leased} | {:error, :lost} | {:error, term()}
  def lease(conn, runner_job_name, leased_by, lease_duration_seconds)
      when is_binary(runner_job_name) and is_binary(leased_by) and
             is_integer(lease_duration_seconds) and lease_duration_seconds >= 0 do
    with {:ok, object} <- kube_get(conn, runner_job_name),
         {:ok, status} <- current_status(object) do
      if RunnerJobStatus.legal_transition?(status.phase, :leased) do
        new_status = %{
          status
          | phase: :leased,
            leased_by: leased_by,
            lease_expires_at: expires_at_iso8601(lease_duration_seconds)
        }

        cas_patch(conn, runner_job_name, object, new_status, :leased)
      else
        {:error, :lost}
      end
    end
  end

  @doc """
  Confirm acquisition of a previously-leased `RunnerJob`: the runner
  identified by `leased_by` acks the lease it won, transitioning the
  status from `Leased` to `Acquired`.

  Only succeeds when the current status is legally transitionable
  `Leased -> Acquired` *and* the recorded `leasedBy` matches `leased_by` —
  a caller confirming a lease it does not hold is treated identically to
  a caller that lost the original race.

  Returns:

    * `{:ok, :acquired}` — the CAS landed; the `RunnerJob` status now
      shows phase `Acquired` with `acquiredAt` set.
    * `{:error, :lost}` — the job was not `Leased` to `leased_by` when
      read, or another write (e.g. the controller sweeper marking the
      lease `Abandoned`) landed first and the CAS was rejected.
    * `{:error, term()}` — any other `KubeClient` or decoding failure.
  """
  @spec confirm_acquisition(conn(), runner_job_name(), leased_by()) ::
          {:ok, :acquired} | {:error, :lost} | {:error, term()}
  def confirm_acquisition(conn, runner_job_name, leased_by)
      when is_binary(runner_job_name) and is_binary(leased_by) do
    with {:ok, object} <- kube_get(conn, runner_job_name),
         {:ok, status} <- current_status(object) do
      if RunnerJobStatus.legal_transition?(status.phase, :acquired) and
           status.leased_by == leased_by do
        new_status = %{status | phase: :acquired, acquired_at: now_iso8601()}
        cas_patch(conn, runner_job_name, object, new_status, :acquired)
      else
        {:error, :lost}
      end
    end
  end

  # -- internal ----------------------------------------------------------

  @spec current_status(map()) :: {:ok, RunnerJobStatus.t()} | {:error, term()}
  defp current_status(object) do
    object
    |> Map.get("status", %{})
    |> RunnerJobStatus.from_wire()
  end

  # Attempts the resourceVersion-CAS write of `new_status` against the
  # resourceVersion carried on `object` (as read, before this call decided
  # anything). A lost CAS (`{:error, :conflict}`) is translated to
  # `{:error, :lost}` here, once, so both public entry points share
  # identical race-loss semantics — never a forced write.
  @spec cas_patch(conn(), runner_job_name(), map(), RunnerJobStatus.t(), atom()) ::
          {:ok, atom()} | {:error, :lost} | {:error, term()}
  defp cas_patch(conn, runner_job_name, object, %RunnerJobStatus{} = new_status, ok_tag) do
    expected_resource_version = get_in(object, ["metadata", "resourceVersion"])

    case kube_patch_status(
           conn,
           runner_job_name,
           RunnerJobStatus.to_wire(new_status),
           expected_resource_version
         ) do
      {:ok, _updated} -> {:ok, ok_tag}
      {:error, :conflict} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec expires_at_iso8601(non_neg_integer()) :: String.t()
  defp expires_at_iso8601(lease_duration_seconds) do
    DateTime.utc_now()
    |> DateTime.add(lease_duration_seconds, :second)
    |> DateTime.to_iso8601()
  end

  @spec now_iso8601() :: String.t()
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp kube_get({client_module, raw_conn}, name),
    do: client_module.get(raw_conn, @gvk, @namespace, name)

  defp kube_patch_status({client_module, raw_conn}, name, status, expected_resource_version),
    do:
      client_module.patch_status(
        raw_conn,
        @gvk,
        @namespace,
        name,
        status,
        expected_resource_version
      )
end
