defmodule SimRunner.Scene.ChaosDirectorTest do
  use ExUnit.Case, async: false

  alias CrestCiContract.RunnerJobStatus
  alias SimRunner.Demo.InProcessKubeClient
  alias SimRunner.Scene.{ChaosDirector, SceneEvent}

  # `mock_k8s` and `crest_ci_controller` are test-only in_umbrella
  # dependencies of OTHER apps (`crest_ci_gateway`, `crest_ci_controller`
  # itself) that test-depend on `sim_runner` — `sim_runner`'s own
  # `mix.exs` cannot declare a compile-time dependency on either without
  # creating a cycle. Same `Module.concat/1` + `apply/3` dodge
  # `SimRunner.Demo.ControllerInstance` and `SimRunner.Demo.Orchestrator`
  # already use for exactly this reason.
  @resource_store Module.concat([MockK8s, ResourceStore])
  @leader_elector Module.concat([CrestCiController, LeaderElector])

  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  setup do
    # Several tests here hand `ChaosDirector` a pid this test process itself
    # started (via `start_link`, hence linked) precisely so it can kill it
    # (a real elector, a stand-in gateway `Agent`) — trapping exits keeps
    # that `Process.exit(pid, :kill)` from taking this test process down
    # with it.
    Process.flag(:trap_exit, true)

    {:ok, store} = apply(@resource_store, :start_link, [[]])
    kube_conn = {InProcessKubeClient, store}
    %{store: store, kube_conn: kube_conn}
  end

  describe "kill_leader" do
    test "kills the current leader and measures the gap to the next Lease acquisition", %{
      kube_conn: kube_conn
    } do
      election_timings = %{
        lease_duration_seconds: 1,
        renew_interval_ms: 40,
        retry_interval_ms: 20,
        namespace: @namespace,
        lease_name: "test-lease"
      }

      {:ok, elector1} = apply(@leader_elector, :start_link, [kube_conn, "c1", election_timings])
      {:ok, elector2} = apply(@leader_elector, :start_link, [kube_conn, "c2", election_timings])

      leader_identity = wait_for_leader_identity(kube_conn, "test-lease", 2_000)

      leader_pid =
        case leader_identity do
          "c1" -> elector1
          "c2" -> elector2
        end

      timeline = [%SceneEvent{at_ms: 0, kind: :kill_leader, detail: %{}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          controllers: [
            %{identity: "c1", pid: elector1},
            %{identity: "c2", pid: elector2}
          ],
          namespace: @namespace,
          lease_name: "test-lease",
          tick_interval_ms: 15,
          poll_interval_ms: 10,
          leader_gap_timeout_ms: 5_000,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 3_000
      assert line =~ "KillLeader"
      assert line =~ leader_identity

      history = ChaosDirector.history(director)
      assert [%{kind: :kill_leader, killed_identity: ^leader_identity, gap_ms: gap_ms}] = history
      assert is_integer(gap_ms)
      assert gap_ms >= 0

      refute Process.alive?(leader_pid)
    end

    test "narrates and skips when no leader is currently elected", %{kube_conn: kube_conn} do
      timeline = [%SceneEvent{at_ms: 0, kind: :kill_leader, detail: %{}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          controllers: [],
          lease_name: "unelected-lease",
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 1_000
      assert line =~ "no leader currently elected"

      assert [%{kind: :skipped}] = ChaosDirector.history(director)
    end
  end

  describe "kill_gateway" do
    test "kills the gateway pid and counts only the in-flight jobs that go on to complete", %{
      kube_conn: kube_conn
    } do
      {module, conn} = kube_conn

      create_runner_job(module, conn, "job-rehomed", :acquired)
      create_runner_job(module, conn, "job-stuck", :leased)

      {:ok, gateway_pid} = Agent.start_link(fn -> :ok end)

      # Simulate "job-rehomed" surviving the gateway kill and completing on
      # the other replica shortly after — "job-stuck" never completes, so
      # only one of the two in-flight jobs should count as re-homed.
      spawn(fn ->
        Process.sleep(60)
        complete_job(module, conn, "job-rehomed")
      end)

      timeline = [%SceneEvent{at_ms: 0, kind: :kill_gateway, detail: %{}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          gateways: [%{pid: gateway_pid, url: "http://gw-1"}],
          tick_interval_ms: 15,
          poll_interval_ms: 10,
          rehome_settle_ms: 500,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 2_000
      assert line =~ "KillGateway"

      assert [
               %{
                 kind: :kill_gateway,
                 killed_url: "http://gw-1",
                 at_risk: 2,
                 rehomed_runners: 1
               }
             ] = ChaosDirector.history(director)

      refute Process.alive?(gateway_pid)
    end

    test "narrates and skips once the gateway pool is exhausted", %{kube_conn: kube_conn} do
      timeline = [%SceneEvent{at_ms: 0, kind: :kill_gateway, detail: %{}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          gateways: [],
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 1_000
      assert line =~ "no gateway replicas remaining"
      assert [%{kind: :skipped}] = ChaosDirector.history(director)
    end
  end

  describe "burst" do
    test "submits N runs via the injected submit_fun and records how many succeeded", %{
      kube_conn: kube_conn
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      submit_fun = fn ->
        Agent.update(counter, &(&1 + 1))
        {:ok, "run-stub-#{Agent.get(counter, & &1)}"}
      end

      timeline = [%SceneEvent{at_ms: 0, kind: :burst, detail: %{count: 5}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          submit_fun: submit_fun,
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 1_000
      assert line =~ "Burst"
      assert line =~ "5/5"

      assert [%{kind: :burst, requested: 5, submitted: 5}] = ChaosDirector.history(director)
      assert Agent.get(counter, & &1) == 5
    end

    test "a :submit event submits exactly one run", %{kube_conn: kube_conn} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      submit_fun = fn -> Agent.get_and_update(counter, &{{:ok, "run-#{&1}"}, &1 + 1}) end

      timeline = [%SceneEvent{at_ms: 0, kind: :submit, detail: %{}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          submit_fun: submit_fun,
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, _line}}, 1_000
      assert [%{kind: :burst, requested: 1, submitted: 1}] = ChaosDirector.history(director)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "narrate" do
    test "emits the detail message with no side effect", %{kube_conn: kube_conn} do
      timeline = [%SceneEvent{at_ms: 0, kind: :narrate, detail: %{message: "scene start"}}]

      {:ok, director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, "scene start"}}, 1_000
      assert [%{kind: :narrate}] = ChaosDirector.history(director)
    end
  end

  describe "default submit_fun" do
    test "submits a real WorkflowRun from the scene workflow library when no submit_fun is injected",
         %{kube_conn: kube_conn} do
      timeline = [%SceneEvent{at_ms: 0, kind: :submit, detail: %{}}]

      {:ok, _director} =
        ChaosDirector.start_link(
          kube_conn: kube_conn,
          timeline: timeline,
          repo: "crest-ci/chaos-default-test",
          tick_interval_ms: 15,
          notify: self()
        )

      assert_receive {ChaosDirector, _pid, {:narration, line}}, 1_000
      assert line =~ "1/1"

      {module, conn} = kube_conn

      {:ok, runs, _continue} =
        module.list(conn, {"ci.crest.dev", "v1alpha1", "WorkflowRun"}, @namespace, [])

      assert length(runs) == 1
      assert get_in(hd(runs), ["spec", "repo"]) == "crest-ci/chaos-default-test"
    end
  end

  # -- helpers --------------------------------------------------------------

  defp wait_for_leader_identity(kube_conn, lease_name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_leader_identity(kube_conn, lease_name, deadline)
  end

  defp do_wait_for_leader_identity({module, conn}, lease_name, deadline) do
    case module.get(conn, {"coordination.k8s.io", "v1", "Lease"}, @namespace, lease_name) do
      {:ok, object} ->
        case get_in(object, ["spec", "holderIdentity"]) do
          identity when is_binary(identity) and identity != "" ->
            identity

          _other ->
            wait_or_flunk({module, conn}, lease_name, deadline)
        end

      {:error, _reason} ->
        wait_or_flunk({module, conn}, lease_name, deadline)
    end
  end

  defp wait_or_flunk(kube_conn, lease_name, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("no leader elected within timeout")
    else
      Process.sleep(10)
      do_wait_for_leader_identity(kube_conn, lease_name, deadline)
    end
  end

  defp create_runner_job(module, conn, name, phase) do
    {:ok, status} = RunnerJobStatus.new(%{phase: phase})

    object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "RunnerJob",
      "metadata" => %{"name" => name, "namespace" => @namespace},
      "spec" => %{
        "runRef" => "test-run",
        "jobKey" => "build",
        "runsOn" => ["default"],
        "jobMessage" => %{"jobName" => name, "steps" => [], "result" => "success"}
      },
      "status" => RunnerJobStatus.to_wire(status)
    }

    {:ok, _created} = module.create(conn, @runner_job_gvk, @namespace, object)
  end

  defp complete_job(module, conn, name) do
    {:ok, object} = module.get(conn, @runner_job_gvk, @namespace, name)
    rv = get_in(object, ["metadata", "resourceVersion"])
    {:ok, status} = RunnerJobStatus.new(%{phase: :completed, result: "success"})

    module.patch_status(
      conn,
      @runner_job_gvk,
      @namespace,
      name,
      RunnerJobStatus.to_wire(status),
      rv
    )
  end
end
