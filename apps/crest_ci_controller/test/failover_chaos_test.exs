defmodule CrestCiController.FailoverChaosTest do
  @moduledoc """
  The G3 proof for this slice: leadership fails over fast, and failover
  never duplicates children.

  Boots one `MockK8s.KubeApiHttp.Server` (backed by a real
  `MockK8s.ResourceStore`) and THREE `CrestCiController` instances, each
  its own `applicationService.Controller.LeaderElector` +
  `applicationService.Controller.RunReconciler` +
  `applicationService.Controller.LeaseSweeper` triplet talking to the
  mock server over real HTTP through a minimal `KubeClient` adapter
  defined in this file (so the suite has no dependency on which HTTP
  adapter — real or generated later — ends up wired into production
  code). Ten `WorkflowRun`s with a hand-planned DAG of 4 jobs each (40
  jobs total, comfortably over the 30-job floor) are submitted; while
  `RunnerJob`s are still being created, the current Lease holder's
  instance is killed with `Process.exit(pid, :kill)`.

  Every RunnerJob is externally driven through `Queued -> Leased ->
  Acquired -> Completed` via `patch_status/6` CAS — exactly the sequence
  a real gateway + runner would perform — so this suite has no
  compile-time or runtime dependency on the gateway app.

  All synchronization is on observable state (the Lease object, RunnerJob
  listings, WorkflowRun status) via bounded polling loops — never on a
  fixed timer standing in for "surely it's done by now".
  """

  use ExUnit.Case, async: false

  @moduletag :chaos
  @moduletag timeout: 120_000

  alias CrestCiContract.{PlanJob, Ulid, WorkflowRunSpec}

  @namespace "default"
  # CrestCiController.LeaderElector's own defaults — not overridden, so all
  # three instances contend for the same shared Lease object.
  @lease_namespace "crest-ci-system"
  @lease_name "crest-ci-controller"
  @lease_duration_seconds 2
  @renew_interval_ms 500
  @retry_interval_ms 200
  @failover_budget_ms 10_000
  @run_count 10
  @poll_interval_ms 50
  @lease_poll_timeout_ms 15_000
  @drain_poll_timeout_ms 60_000

  # -- a minimal, self-contained CrestCiContract.KubeClient adapter --------
  #
  # Talks to MockK8s.KubeApiHttp.Server over real HTTP with Req (already a
  # crest_ci_controller dep). Defined here, not in lib/, because this
  # suite's only contract with the rest of the system is
  # `port.Contract.KubeClient` itself — any conforming adapter (this one,
  # or whatever production adapter lands later) is substitutable (LSP).
  defmodule HttpKubeClient do
    @moduledoc false
    @behaviour CrestCiContract.KubeClient

    defstruct [:base_url]

    @spec new(:inet.port_number()) :: t()
    def new(port), do: %__MODULE__{base_url: "http://127.0.0.1:#{port}"}

    @type t :: %__MODULE__{base_url: String.t()}

    @impl true
    def get(%__MODULE__{} = conn, gvk, namespace, name) do
      case request(conn, :get, path(gvk, namespace, name)) do
        {200, body} -> {:ok, body}
        {404, _body} -> {:error, :not_found}
        {status, body} -> {:error, {:http_error, status, body}}
      end
    end

    @impl true
    def list(%__MODULE__{} = conn, gvk, namespace, _opts) do
      case request(conn, :get, path(gvk, namespace, nil)) do
        {200, %{"items" => items} = body} ->
          {:ok, items, get_in(body, ["metadata", "continue"])}

        {status, body} ->
          {:error, {:http_error, status, body}}
      end
    end

    @impl true
    def create(%__MODULE__{} = conn, gvk, namespace, object) do
      case request(conn, :post, path(gvk, namespace, nil), object) do
        {201, body} -> {:ok, body}
        {409, _body} -> {:error, :already_exists}
        {status, body} -> {:error, {:http_error, status, body}}
      end
    end

    @impl true
    def update(%__MODULE__{} = conn, gvk, namespace, object) do
      name = get_in(object, ["metadata", "name"])

      case request(conn, :put, path(gvk, namespace, name), object) do
        {200, body} -> {:ok, body}
        {409, _body} -> {:error, :conflict}
        {404, _body} -> {:error, :not_found}
        {status, body} -> {:error, {:http_error, status, body}}
      end
    end

    @impl true
    def patch_status(%__MODULE__{} = conn, gvk, namespace, name, status, expected_rv) do
      body = %{"status" => status, "expectedResourceVersion" => expected_rv}

      case request(conn, :put, path(gvk, namespace, name) <> "/status", body) do
        {200, resp} -> {:ok, resp}
        {409, _resp} -> {:error, :conflict}
        {404, _resp} -> {:error, :not_found}
        {status_code, resp} -> {:error, {:http_error, status_code, resp}}
      end
    end

    @impl true
    def delete(%__MODULE__{} = conn, gvk, namespace, name) do
      case request(conn, :delete, path(gvk, namespace, name)) do
        {200, _body} -> :ok
        {404, _body} -> {:error, :not_found}
        {status, body} -> {:error, {:http_error, status, body}}
      end
    end

    @impl true
    def watch(_conn, _gvk, _namespace, _from_rv, _callback) do
      # This suite proves failover through bounded polling of observable
      # state, not watch delivery — polling is a legitimate degradation of
      # the same "reconciler observes cluster state" contract watch/5
      # exists for, and keeps this adapter simple. Callers that need a
      # real watch use a different adapter.
      {:error, :not_implemented}
    end

    defp path(gvk, namespace, name) do
      {group, version, plural} = rest_segments(gvk)

      base =
        if group == "core" do
          "/api/#{version}/namespaces/#{namespace}/#{plural}"
        else
          "/apis/#{group}/#{version}/namespaces/#{namespace}/#{plural}"
        end

      if name, do: base <> "/#{name}", else: base
    end

    defp rest_segments({"ci.crest.dev", "v1alpha1", "WorkflowRun"}),
      do: {"ci.crest.dev", "v1alpha1", "workflowruns"}

    defp rest_segments({"ci.crest.dev", "v1alpha1", "RunnerJob"}),
      do: {"ci.crest.dev", "v1alpha1", "runnerjobs"}

    defp rest_segments({"coordination.k8s.io", "v1", "Lease"}),
      do: {"coordination.k8s.io", "v1", "leases"}

    defp rest_segments({"core", "v1", "Pod"}), do: {"core", "v1", "pods"}

    defp request(conn, method, path, body \\ nil) do
      opts = [method: method, url: conn.base_url <> path, retry: false]
      opts = if body, do: Keyword.put(opts, :json, body), else: opts
      resp = Req.request!(opts)
      {resp.status, resp.body}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, store} = MockK8s.ResourceStore.start_link([])
    {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0)
    port = MockK8s.KubeApiHttp.Server.bound_port(server)

    on_exit(fn -> MockK8s.KubeApiHttp.Server.stop(server) end)

    %{conn: HttpKubeClient.new(port)}
  end

  test "leader dies mid-flight: fast failover, zero duplicate children, all runs succeed", %{
    conn: conn
  } do
    identities = ["controller-a", "controller-b", "controller-c"]

    instances =
      Map.new(identities, fn identity -> {identity, start_instance!(conn, identity)} end)

    on_exit(fn ->
      Enum.each(Map.values(instances), fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end)

    {initial_leader, _initial_acquire_time} = wait_for_leader(conn)
    assert initial_leader in identities

    runs = for i <- 1..@run_count, do: submit_workflow_run(conn, i)

    # mid-flight: at least one RunnerJob exists but the full 40-job plan
    # has not all landed yet.
    wait_until("first RunnerJobs to appear", @lease_poll_timeout_ms, fn ->
      {:ok, jobs, _continue} = HttpKubeClient.list(conn, runner_job_gvk(), @namespace, [])
      jobs != []
    end)

    {leader_identity, _acquire_time} = current_lease_holder(conn)
    leader_pid = Map.fetch!(instances, leader_identity)

    kill_started_at = System.monotonic_time(:millisecond)
    ref = Process.monitor(leader_pid)
    Process.exit(leader_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^leader_pid, _reason} -> :ok
    after
      5_000 -> flunk("killed leader instance #{leader_identity} did not go down")
    end

    {new_leader, _new_acquire_time} = wait_for_new_leader(conn, leader_identity)
    failover_gap_ms = System.monotonic_time(:millisecond) - kill_started_at

    IO.puts("failover_gap_ms=#{failover_gap_ms}")
    assert new_leader != leader_identity
    assert failover_gap_ms < @failover_budget_ms

    # externally satisfy every RunnerJob the way a gateway + runner would,
    # until every submitted run reaches a terminal phase.
    wait_until("all runs to reach a terminal phase", @drain_poll_timeout_ms, fn ->
      {:ok, jobs, _continue} = HttpKubeClient.list(conn, runner_job_gvk(), @namespace, [])
      Enum.each(jobs, &advance_runner_job(conn, &1))

      Enum.all?(runs, fn run -> terminal_phase?(run_phase(conn, run.name)) end)
    end)

    succeeded = Enum.count(runs, fn run -> run_phase(conn, run.name) == "Succeeded" end)
    IO.puts("runs_succeeded=#{succeeded}")
    assert succeeded == @run_count

    duplicate_children = count_duplicate_children(conn)
    IO.puts("duplicate_children=#{duplicate_children}")
    assert duplicate_children == 0
  end

  # -- instance lifecycle ---------------------------------------------------

  # One "controller instance" = its own `CrestCiController.LeaderElector` +
  # `CrestCiController.RunReconciler`, pointed at the same kube_conn and
  # sharing the Lease via LeaderElector's own defaults (namespace
  # "crest-ci-system", name "crest-ci-controller") per the design
  # contract's "start_link-able with (kube conn, identity, election
  # timings)" note. RunReconciler defers to its own instance's
  # LeaderElector pid (`leader?/1`) so only the leader's reconciler
  # executes side effects. Both are started from a dedicated process (not
  # the test process) so that process's links are exactly this instance's
  # lifetime: killing it (`Process.exit(pid, :kill)`) takes both down the
  # same way killing a real supervisor would, without this test needing
  # to know their internal supervision tree.
  @spec start_instance!(HttpKubeClient.t(), String.t()) :: pid()
  defp start_instance!(conn, identity) do
    kube_conn = {HttpKubeClient, conn}

    election_timings = %{
      lease_duration_seconds: @lease_duration_seconds,
      renew_interval_ms: @renew_interval_ms,
      retry_interval_ms: @retry_interval_ms
    }

    parent = self()
    ready_ref = make_ref()

    # Deliberately `spawn` (not `spawn_link`): this wrapper must NOT be
    # linked to the test process itself, or killing it with
    # `Process.exit/2` below would propagate the same `:killed` exit
    # signal back to the test runner and tear the whole test down. It
    # calling `start_link/…` on the two GenServers from *within* itself is
    # what makes it their supervisor for lifecycle purposes: they link to
    # this wrapper, not to the test process.
    pid =
      spawn(fn ->
        {:ok, leader_elector} =
          CrestCiController.LeaderElector.start_link(kube_conn, identity, election_timings)

        {:ok, _run_reconciler} =
          CrestCiController.RunReconciler.start_link(kube_conn, leader_elector, %{
            namespace: @namespace,
            poll_interval_ms: @poll_interval_ms
          })

        send(parent, {ready_ref, :ready})

        receive do
        after
          :infinity -> :ok
        end
      end)

    receive do
      {^ready_ref, :ready} -> pid
    after
      5_000 -> flunk("controller instance #{identity} did not finish booting")
    end
  end

  # -- WorkflowRun submission -------------------------------------------------

  defp submit_workflow_run(conn, index) do
    name = "chaos-run-#{index}-#{Ulid.generate()}"

    {:ok, spec} =
      WorkflowRunSpec.new(%{
        repo: "crest/example",
        ref: "refs/heads/main",
        sha: String.duplicate("a", 40),
        plan: plan_jobs!()
      })

    object = %{
      "metadata" => %{"name" => name},
      "spec" => WorkflowRunSpec.to_wire(spec)
    }

    {:ok, created} = HttpKubeClient.create(conn, workflow_run_gvk(), @namespace, object)
    %{name: get_in(created, ["metadata", "name"])}
  end

  # 4 jobs/run * 10 runs = 40 jobs total, over the 30-job floor.
  defp plan_jobs! do
    {:ok, build} =
      PlanJob.new(%{
        key: "build",
        needs: [],
        runs_on: ["linux"],
        steps: [%{"run" => "echo build"}]
      })

    {:ok, unit_test} =
      PlanJob.new(%{
        key: "unit_test",
        needs: ["build"],
        runs_on: ["linux"],
        steps: [%{"run" => "echo unit_test"}]
      })

    {:ok, integration_test} =
      PlanJob.new(%{
        key: "integration_test",
        needs: ["build"],
        runs_on: ["linux"],
        steps: [%{"run" => "echo integration_test"}]
      })

    {:ok, deploy} =
      PlanJob.new(%{
        key: "deploy",
        needs: ["unit_test", "integration_test"],
        runs_on: ["linux"],
        steps: [%{"run" => "echo deploy"}]
      })

    [build, unit_test, integration_test, deploy]
  end

  # -- externally satisfying RunnerJobs (standing in for gateway+runner) ---

  defp advance_runner_job(conn, job) do
    name = get_in(job, ["metadata", "name"])
    phase = get_in(job, ["status", "phase"]) || "Queued"

    case phase do
      "Queued" ->
        patch_runner_job(conn, name, job, "Leased", %{
          "leasedBy" => "chaos-test-runner",
          "leaseExpiresAt" => far_future_iso()
        })

      "Leased" ->
        patch_runner_job(conn, name, job, "Acquired", %{"acquiredAt" => now_iso()})

      "Acquired" ->
        patch_runner_job(conn, name, job, "Completed", %{"result" => "success"})

      _terminal_or_unknown ->
        :ok
    end
  end

  defp patch_runner_job(conn, name, job, wire_phase, extra_fields) do
    rv = get_in(job, ["metadata", "resourceVersion"])

    status =
      job
      |> Map.get("status", %{})
      |> Map.merge(extra_fields)
      |> Map.put("phase", wire_phase)

    case HttpKubeClient.patch_status(conn, runner_job_gvk(), @namespace, name, status, rv) do
      {:ok, _updated} -> :ok
      # a lost CAS or a since-deleted object just means the next poll
      # tick re-reads fresh state and tries again.
      {:error, :conflict} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp run_phase(conn, name) do
    case HttpKubeClient.get(conn, workflow_run_gvk(), @namespace, name) do
      {:ok, run} -> get_in(run, ["status", "phase"]) || "Pending"
      {:error, :not_found} -> "Pending"
    end
  end

  defp terminal_phase?(phase), do: phase in ["Succeeded", "Failed", "Cancelled"]

  # -- leadership observation (Lease CR only, never LeaderElector internals) -

  defp wait_for_leader(conn) do
    wait_until("an initial Lease holder to be elected", @lease_poll_timeout_ms, fn ->
      case HttpKubeClient.get(conn, lease_gvk(), @lease_namespace, @lease_name) do
        {:ok, lease} -> get_in(lease, ["spec", "holderIdentity"]) not in [nil, ""]
        {:error, :not_found} -> false
      end
    end)

    current_lease_holder(conn)
  end

  defp wait_for_new_leader(conn, previous_identity) do
    wait_until(
      "a new Lease holder after killing #{previous_identity}",
      @failover_budget_ms * 3,
      fn ->
        case HttpKubeClient.get(conn, lease_gvk(), @lease_namespace, @lease_name) do
          {:ok, lease} ->
            get_in(lease, ["spec", "holderIdentity"]) not in [nil, "", previous_identity]

          {:error, :not_found} ->
            false
        end
      end
    )

    current_lease_holder(conn)
  end

  defp current_lease_holder(conn) do
    {:ok, lease} = HttpKubeClient.get(conn, lease_gvk(), @lease_namespace, @lease_name)
    {get_in(lease, ["spec", "holderIdentity"]), get_in(lease, ["spec", "acquireTime"])}
  end

  # -- duplicate-children assertion -----------------------------------------

  # Exactly one child per (run, jobKey): RunnerJobs carry that identity
  # directly on spec (runRef/jobKey); Pods are grouped by the RunnerJob
  # they're owned by (ownerReferences), since deterministic naming ties a
  # RunnerJob to at most one pod per the "409 AlreadyExists is success"
  # reconciliation rule.
  defp count_duplicate_children(conn) do
    {:ok, jobs, _continue} = HttpKubeClient.list(conn, runner_job_gvk(), @namespace, [])
    {:ok, pods, _continue} = HttpKubeClient.list(conn, pod_gvk(), @namespace, [])

    job_duplicates =
      jobs
      |> Enum.group_by(fn job ->
        {get_in(job, ["spec", "runRef"]), get_in(job, ["spec", "jobKey"])}
      end)
      |> Enum.map(fn {_key, group} -> length(group) - 1 end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sum()

    pod_duplicates =
      pods
      |> Enum.group_by(&owner_reference_name/1)
      |> Map.delete(nil)
      |> Enum.map(fn {_owner_name, group} -> length(group) - 1 end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sum()

    job_duplicates + pod_duplicates
  end

  defp owner_reference_name(object) do
    case get_in(object, ["metadata", "ownerReferences"]) do
      [%{"name" => name} | _rest] -> name
      _other -> nil
    end
  end

  # -- gvks -------------------------------------------------------------

  defp workflow_run_gvk, do: {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  defp runner_job_gvk, do: {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  defp lease_gvk, do: {"coordination.k8s.io", "v1", "Lease"}
  defp pod_gvk, do: {"core", "v1", "Pod"}

  # -- bounded polling: never a fixed timer standing in for "surely done" ---

  defp wait_until(description, timeout_ms, condition_fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_deadline(description, deadline, condition_fun)
  end

  defp poll_until_deadline(description, deadline, condition_fun) do
    if condition_fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for: #{description}")
      else
        Process.sleep(@poll_interval_ms)
        poll_until_deadline(description, deadline, condition_fun)
      end
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp far_future_iso do
    DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
  end
end
