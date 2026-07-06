defmodule SimRunner.Scene.StateSnapshotter do
  @moduledoc """
  `domainService.Scene.StateSnapshotter` — pure, given fetched inputs:
  assembles a `SimRunner.Scene.Snapshot` from listed custom resources
  (`WorkflowRun`, `RunnerJob`, `Lease`, `Pod`) — the single source the
  scene's renderer sees. No side channel into `SimRunner.Demo.Orchestrator`
  (or any other director) or into this process's own state ever leaks into
  a `Snapshot`: every field is a derivation of the object lists handed to
  `from_resources/6`, nothing more.

  ## Two collaborators, one reason each to change

  `take/3` is the only impure edge: it lists the four object collections
  through the injected `CrestCiContract.KubeClient` port (Dependency
  Inversion — this module never hardcodes an adapter, only accepts
  `{adapter_module, adapter_conn}` from whatever composed it) and hands
  them straight to `from_resources/6`, which does all the actual
  derivation and has no knowledge of Kubernetes, `conn`s, or pagination.
  `from_resources/6` is what a test exercises directly: identical inputs
  always yield an identical `Snapshot`, so no fake `KubeClient` is needed
  to test the derivation logic itself.

  ## Field derivations

  Reusing the closed-enum value objects already declared for these CRs
  (`CrestCiContract.WorkflowRunStatus`, `WorkflowRunPhase`,
  `RunnerJobStatus`, `LeaseSpec`, `JobStatus`) rather than re-deriving
  phase semantics ad hoc:

    * `done` — count of `WorkflowRun`s whose decoded `WorkflowRunStatus.phase`
      is terminal (`WorkflowRunPhase.terminal?/1`: Succeeded, Failed,
      Cancelled).
    * `runs` — one map per `WorkflowRun`: `"name"`, `"phase"` (wire
      string), `"jobsTotal"`, `"jobsDone"`.
    * `queued` / `leased` / `running` — `RunnerJob` counts bucketed by
      decoded `RunnerJobStatus.phase`: `:queued`, `:leased`, and `:acquired`
      respectively. A `RunnerJob` is "running" once a runner has won the
      acquisition CAS and before it reports a terminal result — there is
      no separate "running" `RunnerJobPhase` value in the closed
      enumeration. `:completed` and `:abandoned` jobs fall into none of
      the three live-dashboard buckets.
    * `acquisitions` / `duplicate_acquisitions` — derived from the
      `acquisitionCount` extension field `SimRunner.Demo.GatewayWiring`
      stamps onto every `RunnerJob`'s status on each real (non-idempotent)
      `Leased -> Acquired` transition (see its moduledoc): `acquisitions`
      is the sum of `acquisitionCount` across all `RunnerJob`s;
      `duplicate_acquisitions` is `sum(max(acquisitionCount - 1, 0))` —
      the same formula `SimRunner.Demo.Orchestrator`'s own post-hoc
      verification pass uses, reused here for the live view.
    * `chunk_count` — sum of `JobStatus.log_chunks` across every job in
      every `WorkflowRunStatus.jobs` map. `JobStatus.update/2` already
      clamps `log_chunks` to `max(current, incoming)`, so this total is
      the idempotent, de-duplicated count — never inflated by a retried
      chunk upload.
    * `cache_hits` / `cache_misses` — counted from each job's
      `JobStatus.outputs["cacheResult"]` (`"hit"` / `"miss"`), the
      convention this project's cache flow
      (`CrestCiGateway.Results.*`, a GitHub-Actions-compatible cache)
      records a job's cache outcome under. Absent or unrecognized outputs
      contribute to neither counter.
    * `leader` / `lease_remaining_s` — decoded from the one coordination
      `Lease` object named `lease_name` (default `"crest-ci-controller"`,
      `CrestCiController.LeaderElector`'s own default): `leader` is its
      `holder_identity`; `lease_remaining_s` is
      `(renew_time + lease_duration_seconds) - now`, which may be
      negative in the brief window between expiry and the next leader's
      renewal being observed. `now` is an injected clock reading
      (`DateTime.utc_now/0` by default) rather than read internally, so
      tests exercise "expired lease" / "healthy lease" readings without
      racing the wall clock. An absent or malformed lease yields
      `leader: ""`, `lease_remaining_s: 0`.
    * `gateways` — one map per `Pod` labeled
      `"crest.dev/component" => "gateway"` (`"name"`, `"phase"` from the
      pod's own `status.phase`, defaulting to `"Unknown"`). This project's
      demo harness's runner-execution pods
      (`SimRunner.Demo.ControllerInstance`) never carry this label, so
      `gateways` is legitimately `[]` in-repo today; the mechanism
      generalizes to a real deployment that labels its gateway pods this
      way.
    * `failovers` — always `[]` here. A single point-in-time listing of
      CRs carries no event history to reconstruct individual failover
      occurrences from; `SimRunner.Scene.Scoreboard`'s
      `controller_failovers` / `gateway_failovers` already own that
      derivation from actual restart bookkeeping (see its moduledoc) — a
      scene director composes the two rather than this module
      reinventing history it cannot see.
    * `elapsed_ms` — passed straight through from the caller; no CR here
      carries a "scene start time" to derive it from.

  Any object missing or malformed enough to fail its value object's
  `from_wire/1` is treated as that type's zero value (e.g. an undecodable
  `WorkflowRunStatus` counts as `phase: :pending`, `jobs: %{}`; an
  undecodable `RunnerJobStatus` counts as `phase: :queued`) rather than
  failing the whole snapshot — a single corrupt/incomplete watch delivery
  must never take down the live dashboard.
  """

  alias CrestCiContract.{
    JobStatus,
    KubeClient,
    LeaseSpec,
    RunnerJobStatus,
    WorkflowRunPhase,
    WorkflowRunStatus
  }

  alias SimRunner.Scene.Snapshot

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @lease_gvk {"coordination.k8s.io", "v1", "Lease"}
  @pod_gvk {"core", "v1", "Pod"}
  @namespace "default"
  @default_lease_name "crest-ci-controller"
  @gateway_component_label "crest.dev/component"
  @gateway_component_value "gateway"

  @typedoc "`{adapter_module, adapter_conn}` — see `CrestCiContract.KubeClient`."
  @type kube_conn :: {module(), KubeClient.conn()}

  @doc """
  Lists `WorkflowRun`, `RunnerJob`, `Lease`, and `Pod` objects through
  `kube_conn` (the injected `CrestCiContract.KubeClient` adapter pair) and
  assembles a `Snapshot` from them via `from_resources/6`. `elapsed_ms` is
  the caller's own wall-clock reading since the scene started — this
  module has nothing else to derive it from.

  Options:

    * `:namespace` — defaults to `"default"`.
    * `:lease_name` — the coordination Lease to read `leader` /
      `lease_remaining_s` from; defaults to `"crest-ci-controller"`
      (`CrestCiController.LeaderElector`'s own default).
    * `:now` — clock reading used for `lease_remaining_s`; defaults to
      `DateTime.utc_now/0`.

  Returns `{:error, reason}` only when a `list/4` call itself fails (a
  transport error, never a decode failure — decode failures are absorbed,
  see the moduledoc).
  """
  @spec take(kube_conn(), non_neg_integer(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def take({module, conn}, elapsed_ms, opts \\ [])
      when is_integer(elapsed_ms) and elapsed_ms >= 0 and is_list(opts) do
    namespace = Keyword.get(opts, :namespace, @namespace)
    lease_name = Keyword.get(opts, :lease_name, @default_lease_name)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, runs} <- list_all(module, conn, @workflow_run_gvk, namespace),
         {:ok, jobs} <- list_all(module, conn, @runner_job_gvk, namespace),
         {:ok, leases} <- list_all(module, conn, @lease_gvk, namespace),
         {:ok, pods} <- list_all(module, conn, @pod_gvk, namespace) do
      from_resources(runs, jobs, leases, pods, elapsed_ms, lease_name: lease_name, now: now)
    end
  end

  @doc """
  Pure core: assembles a `Snapshot` from already-fetched object lists —
  see the moduledoc for every field's derivation. Identical inputs always
  yield an identical `Snapshot`; there is no I/O and no process state read
  here (aside from the injectable `:now` clock reading used only for
  `lease_remaining_s`).

  Options:

    * `:lease_name` — defaults to `"crest-ci-controller"`.
    * `:now` — defaults to `DateTime.utc_now/0`.
  """
  @spec from_resources(
          [KubeClient.object()],
          [KubeClient.object()],
          [KubeClient.object()],
          [KubeClient.object()],
          non_neg_integer(),
          keyword()
        ) :: {:ok, Snapshot.t()} | {:error, term()}
  def from_resources(runs, jobs, leases, pods, elapsed_ms, opts \\ [])
      when is_list(runs) and is_list(jobs) and is_list(leases) and is_list(pods) and
             is_integer(elapsed_ms) and elapsed_ms >= 0 and is_list(opts) do
    lease_name = Keyword.get(opts, :lease_name, @default_lease_name)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    run_statuses = Enum.map(runs, &decode_run_status/1)
    job_statuses = Enum.map(jobs, &decode_job_status/1)

    {leader, lease_remaining_s} = project_lease(leases, lease_name, now)

    Snapshot.new(%{
      acquisitions: sum_acquisitions(jobs),
      cache_hits: cache_outcomes(run_statuses, "hit"),
      cache_misses: cache_outcomes(run_statuses, "miss"),
      chunk_count: sum_log_chunks(run_statuses),
      done: Enum.count(run_statuses, &WorkflowRunPhase.terminal?(&1.phase)),
      duplicate_acquisitions: sum_duplicate_acquisitions(jobs),
      elapsed_ms: elapsed_ms,
      failovers: [],
      gateways: project_gateways(pods),
      leader: leader,
      lease_remaining_s: lease_remaining_s,
      leased: count_runner_jobs(job_statuses, :leased),
      queued: count_runner_jobs(job_statuses, :queued),
      running: count_runner_jobs(job_statuses, :acquired),
      runs: project_runs(runs, run_statuses)
    })
  end

  # -- WorkflowRun / RunnerJob decoding ---------------------------------------

  @spec decode_run_status(KubeClient.object()) :: WorkflowRunStatus.t()
  defp decode_run_status(object) do
    case WorkflowRunStatus.from_wire(Map.get(object, "status", %{})) do
      {:ok, status} -> status
      {:error, _reason} -> WorkflowRunStatus.new(%{})
    end
  end

  @spec decode_job_status(KubeClient.object()) :: RunnerJobStatus.t()
  defp decode_job_status(object) do
    case RunnerJobStatus.from_wire(Map.get(object, "status", %{})) do
      {:ok, status} -> status
      {:error, _reason} -> %RunnerJobStatus{phase: :queued}
    end
  end

  # -- runs --------------------------------------------------------------------

  @spec project_runs([KubeClient.object()], [WorkflowRunStatus.t()]) :: [map()]
  defp project_runs(runs, run_statuses) do
    runs
    |> Enum.zip(run_statuses)
    |> Enum.map(fn {object, status} ->
      jobs_done =
        status.jobs
        |> Map.values()
        |> Enum.count(&(&1.phase in [:succeeded, :skipped]))

      %{
        "name" => get_in(object, ["metadata", "name"]) || "",
        "phase" => WorkflowRunPhase.to_wire(status.phase),
        "jobsTotal" => map_size(status.jobs),
        "jobsDone" => jobs_done
      }
    end)
  end

  # -- RunnerJob counters --------------------------------------------------------

  @spec count_runner_jobs([RunnerJobStatus.t()], RunnerJobStatus.phase()) :: non_neg_integer()
  defp count_runner_jobs(job_statuses, phase) do
    Enum.count(job_statuses, &(&1.phase == phase))
  end

  @spec sum_acquisitions([KubeClient.object()]) :: non_neg_integer()
  defp sum_acquisitions(jobs) do
    jobs |> Enum.map(&acquisition_count/1) |> Enum.sum()
  end

  @spec sum_duplicate_acquisitions([KubeClient.object()]) :: non_neg_integer()
  defp sum_duplicate_acquisitions(jobs) do
    jobs |> Enum.map(&acquisition_count/1) |> Enum.map(&max(&1 - 1, 0)) |> Enum.sum()
  end

  @spec acquisition_count(KubeClient.object()) :: non_neg_integer()
  defp acquisition_count(object) do
    case object |> Map.get("status", %{}) |> Map.get("acquisitionCount", 0) do
      count when is_integer(count) and count >= 0 -> count
      _other -> 0
    end
  end

  # -- log chunks / cache outcomes, from WorkflowRunStatus.jobs -----------------

  @spec sum_log_chunks([WorkflowRunStatus.t()]) :: non_neg_integer()
  defp sum_log_chunks(run_statuses) do
    run_statuses
    |> Enum.flat_map(fn status -> Map.values(status.jobs) end)
    |> Enum.map(& &1.log_chunks)
    |> Enum.sum()
  end

  @spec cache_outcomes([WorkflowRunStatus.t()], String.t()) :: non_neg_integer()
  defp cache_outcomes(run_statuses, outcome) do
    run_statuses
    |> Enum.flat_map(fn status -> Map.values(status.jobs) end)
    |> Enum.count(fn %JobStatus{outputs: outputs} ->
      Map.get(outputs, "cacheResult") == outcome
    end)
  end

  # -- Lease ---------------------------------------------------------------------

  @spec project_lease([KubeClient.object()], String.t(), DateTime.t()) :: {String.t(), integer()}
  defp project_lease(leases, lease_name, now) do
    leases
    |> Enum.find(fn object -> get_in(object, ["metadata", "name"]) == lease_name end)
    |> case do
      nil ->
        {"", 0}

      object ->
        case LeaseSpec.from_wire(Map.get(object, "spec", %{})) do
          {:ok, spec} -> {spec.holder_identity, remaining_seconds(spec, now)}
          {:error, _reason} -> {"", 0}
        end
    end
  end

  @spec remaining_seconds(LeaseSpec.t(), DateTime.t()) :: integer()
  defp remaining_seconds(%LeaseSpec{} = spec, now) do
    case DateTime.from_iso8601(spec.renew_time) do
      {:ok, renew_time, _offset} ->
        expiry = DateTime.add(renew_time, spec.lease_duration_seconds, :second)
        DateTime.diff(expiry, now, :second)

      {:error, _reason} ->
        0
    end
  end

  # -- Pods / gateways -------------------------------------------------------------

  @spec project_gateways([KubeClient.object()]) :: [map()]
  defp project_gateways(pods) do
    pods
    |> Enum.filter(&gateway_pod?/1)
    |> Enum.map(fn object ->
      %{
        "name" => get_in(object, ["metadata", "name"]) || "",
        "phase" => get_in(object, ["status", "phase"]) || "Unknown"
      }
    end)
  end

  @spec gateway_pod?(KubeClient.object()) :: boolean()
  defp gateway_pod?(object) do
    get_in(object, ["metadata", "labels", @gateway_component_label]) == @gateway_component_value
  end

  # -- pagination ------------------------------------------------------------------

  @spec list_all(module(), term(), KubeClient.gvk(), KubeClient.namespace()) ::
          {:ok, [KubeClient.object()]} | {:error, term()}
  defp list_all(module, conn, gvk, namespace) do
    do_list_all(module, conn, gvk, namespace, nil, [])
  end

  @spec do_list_all(
          module(),
          term(),
          KubeClient.gvk(),
          KubeClient.namespace(),
          KubeClient.continue_token(),
          [KubeClient.object()]
        ) :: {:ok, [KubeClient.object()]} | {:error, term()}
  defp do_list_all(module, conn, gvk, namespace, continue, acc) do
    opts = if continue, do: [continue: continue], else: []

    case module.list(conn, gvk, namespace, opts) do
      {:ok, objects, nil} -> {:ok, acc ++ objects}
      {:ok, objects, next} -> do_list_all(module, conn, gvk, namespace, next, acc ++ objects)
      {:error, reason} -> {:error, reason}
    end
  end
end
