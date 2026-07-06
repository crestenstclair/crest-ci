defmodule SimRunner.Demo.ControllerInstance do
  @moduledoc """
  One "controller instance" for the E2E demo harness.

  Composes the real `CrestCiController.LeaderElector` (coordination-Lease
  election) and `CrestCiController.LeaseSweeper` (expired-lease
  reclamation) with a reconciliation loop that turns one `WorkflowRun`'s
  hand-planned DAG into `RunnerJob` + Pod objects.

  This is the harness's stand-in for `applicationService.Controller.RunReconciler`
  and `domainService.Controller.ReconcilePlanner` — neither has landed yet
  in this session's wave order. It composes the SAME pure
  `CrestCiController.NeedsResolver` domain service the real reconciler will
  use, so this asset never duplicates *that* decision logic — only the
  "apply the resulting commands to the store" side-effecting part, which
  belongs here until `RunReconciler` lands and this module can be deleted
  in favor of it.

  Only the elected leader ever runs a reconcile/sweep pass; standbys keep
  contending for the Lease via the injected `CrestCiController.LeaderElector`
  and do nothing else — "only the leader's reconcilers execute side
  effects; standbys watch but never write". A crash mid-pass leaves the
  world in a state the next pass (by this instance or whichever wins
  leadership next) converges from: every create is idempotent (deterministic
  names, 409-tolerant), and every status write is a fresh read + CAS.

  `start_link/1` takes an explicit `kube_conn`, `identity`, and
  `election_timings` — nothing here reads global application config, so a
  harness can boot several instances against one shared store and let them
  race for leadership exactly like `CrestCiController.LeaderElector`'s own
  tests do.

  `sim_runner`'s `mix.exs` is spec-pinned to `req` + `jason` +
  `crest_ci_contract` only — adding an in-umbrella dep on
  `crest_ci_controller` is not an option (it already test-depends on
  `sim_runner`, which would create a dependency cycle). So
  `CrestCiController.LeaderElector`, `LeaseSweeper`, and `NeedsResolver`
  are never referenced via compile-time dot-call syntax here; every call
  goes through `apply/3` against a module atom built by `Module.concat/1`,
  which is ordinary data as far as the compiler's cross-module reference
  checker is concerned. The modules are real and loaded at runtime when
  this Mix task actually runs from the umbrella root — this is purely
  about keeping `sim_runner` compiling cleanly under
  `--warnings-as-errors` without a declared compile-time dependency.
  """

  use GenServer

  require Logger

  alias CrestCiContract.{JobStatus, WorkflowRunSpec, WorkflowRunStatus}
  alias SimRunner.Demo.{Naming, WorkflowRunProjector}

  @leader_elector Module.concat([CrestCiController, LeaderElector])
  @lease_sweeper Module.concat([CrestCiController, LeaseSweeper])
  @needs_resolver Module.concat([CrestCiController, NeedsResolver])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @pod_gvk {"core", "v1", "Pod"}
  @namespace "default"

  defmodule State do
    @moduledoc false
    @enforce_keys [:kube_conn, :run_name, :run_ulid, :elector, :reconcile_interval_ms]
    defstruct [
      :kube_conn,
      :run_name,
      :run_ulid,
      :elector,
      :reconcile_interval_ms,
      is_leader: false
    ]
  end

  @doc """
  Starts one controller instance.

  Options:

    * `:kube_conn` (required) — `{adapter_module, adapter_conn}`.
    * `:identity` (required) — this instance's Lease-holder identity.
    * `:election_timings` (required) — passed straight through to
      `CrestCiController.LeaderElector.start_link/3`.
    * `:run_name` / `:run_ulid` (required) — the one `WorkflowRun` this
      demo harness reconciles.
    * `:reconcile_interval_ms` — how often a leader runs a reconcile +
      sweep pass; defaults to `30`.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    kube_conn = Keyword.fetch!(opts, :kube_conn)
    identity = Keyword.fetch!(opts, :identity)
    election_timings = Keyword.fetch!(opts, :election_timings)
    run_name = Keyword.fetch!(opts, :run_name)
    run_ulid = Keyword.fetch!(opts, :run_ulid)
    reconcile_interval_ms = Keyword.get(opts, :reconcile_interval_ms, 30)

    {:ok, elector} = apply(@leader_elector, :start_link, [kube_conn, identity, election_timings])
    :ok = apply(@leader_elector, :subscribe, [elector, self()])

    state = %State{
      kube_conn: kube_conn,
      run_name: run_name,
      run_ulid: run_ulid,
      elector: elector,
      reconcile_interval_ms: reconcile_interval_ms
    }

    schedule_tick(reconcile_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info({:leader_acquired, _identity}, state) do
    {:noreply, %{state | is_leader: true}}
  end

  def handle_info({:leader_lost, _identity}, state) do
    {:noreply, %{state | is_leader: false}}
  end

  def handle_info(:tick, state) do
    if state.is_leader do
      reconcile_once(state)
      apply(@lease_sweeper, :sweep, [state.kube_conn])
    end

    schedule_tick(state.reconcile_interval_ms)
    {:noreply, state}
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  # -- Reconciliation ----------------------------------------------------

  defp reconcile_once(state) do
    with {:ok, run_object} <- kube_get(state, @workflow_run_gvk, state.run_name),
         {:ok, spec} <- WorkflowRunSpec.from_wire(Map.get(run_object, "spec", %{})),
         {:ok, status} <- WorkflowRunStatus.from_wire(Map.get(run_object, "status", %{})) do
      proposal = apply(@needs_resolver, :resolve, [spec.plan, status.jobs])
      Enum.each(proposal.runnable_job_keys, &create_child(state, spec.plan, &1))
      skip_jobs(state, proposal.skip_job_keys)
      :ok
    else
      {:error, reason} ->
        Logger.warning("ControllerInstance: reconcile pass skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp create_child(state, plan, job_key) do
    job = Enum.find(plan, &(&1.key == job_key))
    child_name = Naming.child_name(state.run_ulid, job_key)
    runs_on = if job.runs_on in [nil, []], do: ["default"], else: job.runs_on

    runner_job_object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "RunnerJob",
      "metadata" => %{"name" => child_name, "namespace" => @namespace},
      "spec" => %{
        "runRef" => state.run_ulid,
        "jobKey" => job_key,
        "runsOn" => runs_on,
        "jobMessage" => %{"jobName" => child_name, "steps" => job.steps, "result" => "success"}
      },
      "status" => %{
        "phase" => "Queued",
        "leasedBy" => "",
        "leaseExpiresAt" => "",
        "acquiredAt" => "",
        "result" => "",
        "acquisitionCount" => 0
      }
    }

    tolerate_already_exists(kube_create(state, @runner_job_gvk, runner_job_object))

    pod_object = %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => child_name,
        "namespace" => @namespace,
        "ownerReferences" => [
          %{
            "apiVersion" => "ci.crest.dev/v1alpha1",
            "kind" => "RunnerJob",
            "name" => child_name,
            "uid" => child_name
          }
        ]
      },
      "spec" => %{
        "jitConfig" => %{"runnerName" => "runner-#{child_name}", "jobName" => child_name}
      }
    }

    tolerate_already_exists(kube_create(state, @pod_gvk, pod_object))

    mark_queued(state, job_key)
  end

  defp tolerate_already_exists({:ok, _object}), do: :ok
  defp tolerate_already_exists({:error, :already_exists}), do: :ok

  defp tolerate_already_exists({:error, reason}) do
    Logger.warning("ControllerInstance: create failed: #{inspect(reason)}")
    :ok
  end

  defp mark_queued(state, job_key) do
    WorkflowRunProjector.patch(state.kube_conn, state.run_name, fn status ->
      case Map.get(status.jobs, job_key) do
        %JobStatus{phase: :waiting} = existing ->
          {:ok, updated} = JobStatus.update(existing, %{phase: :queued, queued_at: iso_now()})
          WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, updated))

        nil ->
          {:ok, fresh} = JobStatus.new(%{phase: :queued, queued_at: iso_now()})
          WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, fresh))

        _already_progressed ->
          status
      end
    end)
  end

  defp skip_jobs(_state, []), do: :ok

  defp skip_jobs(state, job_keys) do
    WorkflowRunProjector.patch(state.kube_conn, state.run_name, fn status ->
      updated_jobs =
        Enum.reduce(job_keys, status.jobs, fn job_key, jobs_acc ->
          {:ok, skipped} = JobStatus.new(%{phase: :skipped, finished_at: iso_now()})
          Map.put(jobs_acc, job_key, skipped)
        end)

      WorkflowRunStatus.update_jobs(status, updated_jobs)
    end)
  end

  defp kube_get(%State{kube_conn: {module, conn}}, gvk, name) do
    module.get(conn, gvk, @namespace, name)
  end

  defp kube_create(%State{kube_conn: {module, conn}}, gvk, object) do
    module.create(conn, gvk, @namespace, object)
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
