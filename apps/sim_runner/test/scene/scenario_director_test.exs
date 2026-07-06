defmodule SimRunner.Scene.ScenarioDirectorTest do
  use ExUnit.Case, async: false

  alias SimRunner.Demo.InProcessKubeClient
  alias SimRunner.Scene.ScenarioDirector

  # `mock_k8s` is a test-only in_umbrella dependency of OTHER apps
  # (`crest_ci_gateway`, `crest_ci_controller`) that themselves test-depend
  # on `sim_runner` — `sim_runner`'s own `mix.exs` cannot declare a
  # compile-time dependency on `mock_k8s` without creating a cycle. Same
  # `Module.concat/1` + `apply/3` dodge `SimRunner.Demo.Orchestrator` and
  # `SimRunner.Demo.InProcessKubeClient` already use for exactly this
  # reason — the module is real and on the code path whenever these tests
  # actually run (umbrella-wide `mix test`).
  @resource_store Module.concat([MockK8s, ResourceStore])

  @workflow_run_gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"

  defmodule StubPodWatcher do
    @moduledoc false
    # A stub standing in for `SimRunner.Demo.PodWatcher` in these narrow
    # unit tests: no controller reconciles anything here, so there are
    # never any Pod objects to watch for — this just proves
    # `ScenarioDirector` calls whatever `:pod_watcher_mod` it was given,
    # exactly the way it would call the real `PodWatcher` in production.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      notify = Keyword.get(opts, :notify)
      if notify, do: send(notify, {:pod_watcher_started, opts})
      {:ok, opts}
    end
  end

  setup do
    {:ok, store} = apply(@resource_store, :start_link, [[]])
    kube_conn = {InProcessKubeClient, store}
    %{store: store, kube_conn: kube_conn}
  end

  test "submits a WorkflowRun immediately on start, then continues on a trickle interval", %{
    kube_conn: kube_conn,
    store: store
  } do
    {:ok, director} =
      ScenarioDirector.start_link(
        kube_conn: kube_conn,
        gateway_urls: ["http://localhost:0"],
        interval_ms: 15,
        repo: "crest-ci/scene-test",
        pod_watcher_mod: StubPodWatcher
      )

    wait_until(fn -> ScenarioDirector.submitted_count(director) >= 3 end, 2_000)

    {:ok, runs, _continue} =
      apply(@resource_store, :list, [store, key(@workflow_run_gvk), @namespace, []])

    assert length(runs) >= 3

    Enum.each(runs, fn run ->
      assert get_in(run, ["spec", "repo"]) == "crest-ci/scene-test"
      assert get_in(run, ["spec", "workflowYaml"]) != ""
      assert get_in(run, ["spec", "plan"]) == []
    end)
  end

  test "cycles round-robin through the workflow library in filename order", %{
    kube_conn: kube_conn
  } do
    workflows = [
      {"a.yml", "name: a\njobs: {}\n"},
      {"b.yml", "name: b\njobs: {}\n"},
      {"c.yml", "name: c\njobs: {}\n"}
    ]

    {:ok, director} =
      ScenarioDirector.start_link(
        kube_conn: kube_conn,
        gateway_urls: [],
        workflows: workflows,
        interval_ms: 60_000,
        pod_watcher_mod: StubPodWatcher
      )

    wait_until(fn -> ScenarioDirector.submitted_count(director) >= 1 end, 2_000)

    {:ok, "run-" <> _ = first_run_name} = ScenarioDirector.submit_now(director)
    {:ok, second_run_name} = ScenarioDirector.submit_now(director)
    {:ok, third_run_name} = ScenarioDirector.submit_now(director)

    {module, conn} = kube_conn
    {:ok, first_object} = module.get(conn, @workflow_run_gvk, @namespace, first_run_name)
    {:ok, second_object} = module.get(conn, @workflow_run_gvk, @namespace, second_run_name)
    {:ok, third_object} = module.get(conn, @workflow_run_gvk, @namespace, third_run_name)

    assert get_in(first_object, ["spec", "workflowYaml"]) == "name: b\njobs: {}\n"
    assert get_in(second_object, ["spec", "workflowYaml"]) == "name: c\njobs: {}\n"
    assert get_in(third_object, ["spec", "workflowYaml"]) == "name: a\njobs: {}\n"
  end

  test "starts the injected pod watcher with the given gateway_urls", %{kube_conn: kube_conn} do
    {:ok, _director} =
      ScenarioDirector.start_link(
        kube_conn: kube_conn,
        gateway_urls: ["http://gw-1", "http://gw-2"],
        interval_ms: 60_000,
        pod_watcher_mod: StubPodWatcher,
        notify: self()
      )

    assert_receive {:pod_watcher_started, opts}, 1_000
    assert Keyword.get(opts, :gateway_urls) == ["http://gw-1", "http://gw-2"]
    assert Keyword.get(opts, :kube_conn) == kube_conn
  end

  describe "submit_workflow_run/4" do
    test "submits a run carrying workflowYaml and an empty hand-built plan, and returns its name",
         %{
           kube_conn: kube_conn
         } do
      assert {:ok, run_name} =
               ScenarioDirector.submit_workflow_run(
                 kube_conn,
                 "crest-ci/demo",
                 "name: x\njobs: {}\n"
               )

      assert String.starts_with?(run_name, "run-")

      {module, conn} = kube_conn
      assert {:ok, object} = module.get(conn, @workflow_run_gvk, @namespace, run_name)
      assert get_in(object, ["spec", "workflowYaml"]) == "name: x\njobs: {}\n"
      assert get_in(object, ["spec", "plan"]) == []
    end

    test "a repeated submission never fails with a name collision (ULID-derived names)", %{
      kube_conn: kube_conn
    } do
      assert {:ok, _name_a} =
               ScenarioDirector.submit_workflow_run(
                 kube_conn,
                 "crest-ci/demo",
                 "name: x\njobs: {}\n"
               )

      assert {:ok, _name_b} =
               ScenarioDirector.submit_workflow_run(
                 kube_conn,
                 "crest-ci/demo",
                 "name: x\njobs: {}\n"
               )
    end
  end

  describe "load_workflows/1" do
    test "reads every .yml/.yaml file in the default scene workflow library, sorted by filename" do
      entries = ScenarioDirector.load_workflows()

      filenames = Enum.map(entries, fn {filename, _yaml} -> filename end)
      assert filenames == Enum.sort(filenames)
      assert length(entries) >= 4

      Enum.each(entries, fn {_filename, yaml} -> assert is_binary(yaml) and yaml != "" end)
    end

    test "raises when the directory has no workflow files" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "empty_scene_workflows_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert_raise RuntimeError, fn -> ScenarioDirector.load_workflows(dir) end
    end
  end

  defp key({group, version, kind}), do: "#{group}/#{version}/#{kind}"

  defp wait_until(predicate, timeout_ms, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline, interval_ms)
  end

  defp do_wait_until(predicate, deadline, interval_ms) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(interval_ms)
        do_wait_until(predicate, deadline, interval_ms)
    end
  end
end
