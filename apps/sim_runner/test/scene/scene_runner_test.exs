defmodule SimRunner.Scene.SceneRunnerTest do
  use ExUnit.Case, async: false

  alias SimRunner.Scene.{SceneRunner, Scoreboard, SceneEvent}

  describe "run/1 — happy path" do
    test "boots the stack, trickles workflow runs, and returns a Scoreboard with no failures or duplicate acquisitions" do
      scoreboard =
        SceneRunner.run(%{
          duration_s: 5,
          forever?: false,
          headless?: true,
          controller_count: 1,
          gateway_count: 1,
          scenario_interval_ms: 1_000,
          chaos_timeline: []
        })

      assert %Scoreboard{} = scoreboard
      assert scoreboard.runs_failed == 0
      assert scoreboard.duplicate_acquisitions == 0
      assert scoreboard.runs_succeeded >= 1
    end
  end

  describe "run/1 — DEMO_FOREVER" do
    test "forever? ignores duration_s and stops only once stop_check reports true" do
      {:ok, flag} = Agent.start_link(fn -> false end)

      spawn(fn ->
        Process.sleep(300)
        Agent.update(flag, fn _ -> true end)
      end)

      scoreboard =
        SceneRunner.run(%{
          duration_s: 999_999,
          forever?: true,
          headless?: true,
          controller_count: 1,
          gateway_count: 1,
          chaos_timeline: [],
          tick_interval_ms: 25,
          stop_check: fn -> Agent.get(flag, & &1) end
        })

      assert %Scoreboard{} = scoreboard
    end
  end

  describe "run/1 — chaos: KillLeader" do
    test "an immediate KillLeader event is reflected as an observed controller failover" do
      scoreboard =
        SceneRunner.run(%{
          duration_s: 3,
          forever?: false,
          headless?: true,
          controller_count: 2,
          chaos_timeline: [%SceneEvent{at_ms: 0, kind: :kill_leader, detail: %{}}],
          election_timings: %{
            lease_duration_seconds: 1,
            renew_interval_ms: 30,
            retry_interval_ms: 20
          },
          tick_interval_ms: 50
        })

      assert %Scoreboard{} = scoreboard
      assert scoreboard.controller_failovers >= 1
      assert scoreboard.controller_failover_gap_ms >= 0
    end
  end

  describe "run/1 — chaos: KillGateway" do
    test "an immediate KillGateway event is reflected as an observed gateway failover" do
      scoreboard =
        SceneRunner.run(%{
          duration_s: 3,
          forever?: false,
          headless?: true,
          gateway_count: 2,
          chaos_timeline: [%SceneEvent{at_ms: 0, kind: :kill_gateway, detail: %{}}],
          tick_interval_ms: 50
        })

      assert %Scoreboard{} = scoreboard
      assert scoreboard.gateway_failovers >= 1
    end
  end
end
