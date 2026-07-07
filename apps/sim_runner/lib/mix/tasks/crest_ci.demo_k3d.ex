defmodule Mix.Tasks.CrestCi.DemoK3d do
  @shortdoc "Submits a real WorkflowRun to a live k3d cluster and watches real Pods execute it (MANUAL, out-of-gate)"

  @moduledoc """
  `mix crest_ci.demo_k3d` — the one target in this project that talks to a
  REAL Kubernetes API server instead of `mock_k8s`. It loads the caller's
  current kubeconfig, submits a real `WorkflowRun` carrying this repo's
  `build_test_chain` scene workflow YAML, and watches — polling the live
  cluster only, never a local counter — until the deployed controller (see
  `asset.K3dBootstrap`'s `controller.yaml`) plans the run and creates real,
  ephemeral runner `Pod`s for it.

  This task is MANUAL and out-of-gate: it requires a running k3d cluster
  (`make k3d-up`) with the CRDs and controller/gateway Deployments already
  applied. The mix gate never invokes it — the only gate-checked property
  of this module is that it compiles and exposes `run/1`
  (`apps/sim_runner/test/cluster/demo_k3d_test.exs`), covered by
  `mix compile`. Run it by hand via `make demo-k3d`.

  ## Why this mirrors, rather than reimplements, the in-BEAM demos

  Submission goes through `SimRunner.Scene.ScenarioDirector.submit_workflow_run/4`
  — the exact same pure, process-independent submission path
  `mix crest_ci.demo_scene` uses — so a `WorkflowRun` created against a
  real cluster is built identically to one created in-BEAM against
  `mock_k8s`; only the `conn` differs (real TLS + auth vs. an in-process
  store), per this project's Cluster-context invariant that real-cluster
  orchestration reuses the same reconcile/submission logic rather than a
  parallel implementation that could drift.

  ## What differs from the in-BEAM demos

  There is no local controller or gateway process here: this BEAM only
  submits and observes. Planning (`applicationService.Controller.PlanFromDefinition`)
  and pod orchestration (`applicationService.Cluster.RealPodOrchestrator`)
  happen inside the controller Pods already deployed to the cluster by
  `make k3d-up` — this task never calls either directly, it only watches
  their effect on authoritative cluster state (the `WorkflowRun` status
  subresource, and `RunnerJob`/`Pod` listings), exactly as an operator
  running `kubectl` would.

  ## sim_runner does not depend on crest_ci_controller

  `sim_runner`'s `mix.exs` (hand-maintained, not spec-generated) declares
  deps only on `req`, `jason`, and `crest_ci_contract` — it cannot take a
  compile-time dependency on `crest_ci_controller` (which itself
  test-depends on `sim_runner`, so a direct dep would create a cycle).
  `CrestCiController.Cluster.KubeconfigLoader` and
  `CrestCiController.Cluster.ClusterConnBuilder` are therefore resolved at
  runtime, never referenced as compile-time aliases or literals: the
  target module atom is computed *inside* a function body (never hoisted
  into a `@module_attribute`, whose value the compiler inlines back into
  the call site as a literal — which is exactly what would resurface the
  same "function is undefined" diagnostic `apply/3` is meant to dodge) and
  passed to `apply/3` only after `Code.ensure_loaded?/1` confirms the
  controller app is actually present in the running BEAM, else this task
  fails with a clear `{:error, {:controller_app_not_loaded, module}}`.

  ## Environment variables

    * `KUBECONFIG` — path to the kubeconfig file (default `~/.kube/config`,
      the same default `kubectl` uses).
    * `KUBECONFIG_CONTEXT` — the context to use (default: the kubeconfig's
      `current-context`).
    * `DEMO_K3D_NAMESPACE` — namespace the `WorkflowRun`/`RunnerJob`
      objects live in (default `"default"`).
    * `DEMO_K3D_TIMEOUT_MS` — overall deadline waiting for the run to reach
      a terminal phase (default `300_000`, five minutes — real Pods must
      pull an image and schedule, unlike the in-BEAM demos).
    * `DEMO_K3D_POLL_INTERVAL_MS` — poll cadence against the live API
      (default `2_000`).
    * `DEMO_K3D_CLEANUP_TIMEOUT_MS` — how long to keep polling for
      ownerReference-driven Pod garbage collection after the run goes
      terminal before giving up on counting a Pod as cleaned (default
      `30_000`).

  ## Output

  Prints exactly one summary line, computed only from what the live API
  server reports:

      k3d_runs_succeeded=<n> pods_created=<n> pods_cleaned=<n> jobs_succeeded=<n>

  Exits non-zero (via `Mix.raise/1`) unless `k3d_runs_succeeded == 1` and
  `jobs_succeeded` equals the planned job count for the submitted run.
  """

  use Mix.Task

  alias CrestCiContract.{ReqKubeClient, WorkflowRunStatus}
  alias SimRunner.Scene.ScenarioDirector

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @pod_gvk {"core", "v1", "Pod"}

  @default_kubeconfig_path "~/.kube/config"
  @default_namespace "default"
  @default_timeout_ms 300_000
  @default_poll_interval_ms 2_000
  @default_cleanup_timeout_ms 30_000
  @default_repo "demo/k3d"
  @default_ref "refs/heads/main"
  @workflow_file "build_test_chain.yaml"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    metrics =
      with {:ok, kube_conn} <- build_conn(),
           {:ok, run_name, run_ulid} <- submit_run(kube_conn),
           {:ok, status, seen_pod_names} <- watch_until_terminal(kube_conn, run_name, run_ulid) do
        verify(kube_conn, status, seen_pod_names)
      else
        {:error, reason} ->
          Mix.raise("demo-k3d failed: #{inspect(reason)}")
      end

    IO.puts(summary_line(metrics))

    check!(metrics)
  end

  # -- Connection --------------------------------------------------------

  # The controller's kubeconfig-loading/conn-building modules are resolved
  # entirely at runtime: the module atom is computed inside a function
  # body (never a module attribute, whose value the compiler would inline
  # back into the call site as a literal), and `apply/3` only ever
  # receives that value via a variable bound in a `with` clause — never a
  # literal module + literal function name pair — so
  # `mix compile --warnings-as-errors` has nothing statically resolvable
  # to flag as "module is not available", regardless of whether
  # `crest_ci_controller` happens to be loaded in the running BEAM.
  defp kubeconfig_loader_module, do: Module.concat([CrestCiController, Cluster, KubeconfigLoader])

  defp cluster_conn_builder_module,
    do: Module.concat([CrestCiController, Cluster, ClusterConnBuilder])

  defp build_conn do
    kubeconfig_path =
      System.get_env("KUBECONFIG", @default_kubeconfig_path) |> Path.expand()

    context = System.get_env("KUBECONFIG_CONTEXT")

    with {:ok, loader} <- ensure_controller_module(kubeconfig_loader_module()),
         {:ok, builder} <- ensure_controller_module(cluster_conn_builder_module()),
         {:ok, yaml} <- File.read(kubeconfig_path),
         {:ok, credential} <- apply(loader, :load, [yaml, context]),
         {:ok, conn} <- apply(builder, :build, [credential]) do
      {:ok, {ReqKubeClient, conn}}
    else
      {:error, :enoent} ->
        {:error, {:kubeconfig_not_found, kubeconfig_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_controller_module(module) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:controller_app_not_loaded, module}}
    end
  end

  # -- Submission ----------------------------------------------------------

  defp submit_run(kube_conn) do
    workflow_yaml =
      ScenarioDirector.default_workflows_dir()
      |> Path.join(@workflow_file)
      |> File.read!()

    case ScenarioDirector.submit_workflow_run(kube_conn, @default_repo, workflow_yaml,
           ref: @default_ref
         ) do
      {:ok, run_name} -> {:ok, run_name, run_ulid_from_name(run_name)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_ulid_from_name(run_name), do: String.replace_prefix(run_name, "run-", "")

  # -- Watch -----------------------------------------------------------------

  defp watch_until_terminal(kube_conn, run_name, run_ulid) do
    timeout_ms = env_int("DEMO_K3D_TIMEOUT_MS", @default_timeout_ms)
    interval_ms = env_int("DEMO_K3D_POLL_INTERVAL_MS", @default_poll_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll_loop(kube_conn, run_name, run_ulid, deadline, interval_ms, MapSet.new())
  end

  defp poll_loop(kube_conn, run_name, run_ulid, deadline, interval_ms, seen_pod_names) do
    with {:ok, status} <- fetch_status(kube_conn, run_name) do
      seen_pod_names = MapSet.union(seen_pod_names, live_child_pod_names(kube_conn, run_ulid))

      cond do
        status.phase in [:succeeded, :failed, :cancelled] ->
          {:ok, status, seen_pod_names}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, {:timeout, :run_not_terminal, run_name}}

        true ->
          Process.sleep(interval_ms)
          poll_loop(kube_conn, run_name, run_ulid, deadline, interval_ms, seen_pod_names)
      end
    end
  end

  defp fetch_status({module, conn}, run_name) do
    namespace = env_namespace()

    with {:ok, object} <- module.get(conn, @workflow_run_gvk, namespace, run_name) do
      WorkflowRunStatus.from_wire(Map.get(object, "status", %{}))
    end
  end

  defp live_child_pod_names({module, conn}, run_ulid) do
    namespace = env_namespace()
    prefix = "run-#{run_ulid}-j-"

    case module.list(conn, @pod_gvk, namespace, []) do
      {:ok, pods, _continue} ->
        pods
        |> Enum.map(&get_in(&1, ["metadata", "name"]))
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
    end
  end

  # -- Verification (from authoritative cluster state only) ------------------

  defp verify(kube_conn, %WorkflowRunStatus{} = status, seen_pod_names) do
    runs_succeeded = if status.phase == :succeeded, do: 1, else: 0

    jobs_succeeded =
      status.jobs
      |> Map.values()
      |> Enum.count(&(&1.phase == :succeeded))

    pods_created = MapSet.size(seen_pod_names)
    pods_cleaned = wait_for_pod_cleanup(kube_conn, seen_pod_names)

    %{
      k3d_runs_succeeded: runs_succeeded,
      pods_created: pods_created,
      pods_cleaned: pods_cleaned,
      jobs_succeeded: jobs_succeeded,
      planned_job_count: length(status.plan)
    }
  end

  # ownerReference-driven Pod GC happens asynchronously on the real API
  # server (kube-controller-manager's garbage collector), so cleanup is
  # observed the same way the run's own termination was: polling live
  # state, bounded by a deadline, never a fixed sleep-and-hope.
  defp wait_for_pod_cleanup(kube_conn, seen_pod_names) do
    if MapSet.size(seen_pod_names) == 0 do
      0
    else
      timeout_ms = env_int("DEMO_K3D_CLEANUP_TIMEOUT_MS", @default_cleanup_timeout_ms)
      interval_ms = env_int("DEMO_K3D_POLL_INTERVAL_MS", @default_poll_interval_ms)
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      cleanup_poll(kube_conn, seen_pod_names, deadline, interval_ms)
    end
  end

  defp cleanup_poll({module, conn}, seen_pod_names, deadline, interval_ms) do
    namespace = env_namespace()

    still_present =
      case module.list(conn, @pod_gvk, namespace, []) do
        {:ok, pods, _continue} ->
          pods |> Enum.map(&get_in(&1, ["metadata", "name"])) |> MapSet.new()

        {:error, _reason} ->
          seen_pod_names
      end

    cleaned = MapSet.difference(seen_pod_names, still_present)

    cond do
      MapSet.size(cleaned) == MapSet.size(seen_pod_names) ->
        MapSet.size(cleaned)

      System.monotonic_time(:millisecond) >= deadline ->
        MapSet.size(cleaned)

      true ->
        Process.sleep(interval_ms)
        cleanup_poll({module, conn}, seen_pod_names, deadline, interval_ms)
    end
  end

  # -- Output ------------------------------------------------------------

  defp summary_line(metrics) do
    "k3d_runs_succeeded=#{metrics.k3d_runs_succeeded} " <>
      "pods_created=#{metrics.pods_created} " <>
      "pods_cleaned=#{metrics.pods_cleaned} " <>
      "jobs_succeeded=#{metrics.jobs_succeeded}"
  end

  defp check!(%{k3d_runs_succeeded: k3d_runs_succeeded}) when k3d_runs_succeeded != 1 do
    Mix.raise("demo-k3d failed: k3d_runs_succeeded=#{k3d_runs_succeeded}, expected 1")
  end

  defp check!(%{jobs_succeeded: jobs_succeeded, planned_job_count: planned_job_count})
       when jobs_succeeded != planned_job_count do
    Mix.raise("demo-k3d failed: jobs_succeeded=#{jobs_succeeded}, expected #{planned_job_count}")
  end

  defp check!(_metrics), do: :ok

  # -- Env helpers ---------------------------------------------------------

  defp env_namespace, do: System.get_env("DEMO_K3D_NAMESPACE", @default_namespace)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
