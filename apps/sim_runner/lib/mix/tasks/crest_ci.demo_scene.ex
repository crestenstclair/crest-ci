defmodule Mix.Tasks.CrestCi.DemoScene do
  @shortdoc "The narrated live demo: ANSI dashboard, scripted chaos, measured exit scoreboard"

  @moduledoc """
  `mix crest_ci.demo_scene` — the watchable, narrated demo. Boots the full
  in-BEAM stack (mock-k8s, three controller instances behind a coordination
  Lease, two gateway replicas, and content/blob stores rooted in fresh temp
  dirs), starts a `SimRunner.Scene.ScenarioDirector` submitting real
  workflow YAML from `apps/sim_runner/priv/scene_workflows/` on a steady
  trickle, and a `SimRunner.Scene.ChaosDirector` executing a scripted
  timeline against the running cluster (kill the controller leader, kill a
  gateway replica, fire a burst of runs). A live dashboard redraws a few
  times a second from state derived only from Kubernetes custom resources
  — never from process/director internals — exactly like a real operator
  dashboard would.

  `SimRunner.Scene.SceneRunner` is the conductor: it owns the
  snapshot -> render tick loop, the scene's stop condition, the
  post-run verification pass, and the resulting
  `SimRunner.Scene.Scoreboard` — every counter in it is computed from
  authoritative state after the scene stops, never accumulated from
  director-side bookkeeping while the scene was running. This task is a
  thin CLI edge: it turns environment variables into scene options,
  invokes the conductor, and is responsible for the one contract every
  caller of `mix crest_ci.demo_scene` can rely on regardless of how the
  dashboard renders: exactly one machine-parseable summary line on
  stdout, and a non-zero exit when the scene's own invariants were
  violated.

  ## Environment variables

    * `DEMO_DURATION` — scene duration in seconds (default `90`). The
      default chaos timeline (`KillLeader` ~t+20s, `KillGateway` ~t+35s,
      `Burst` ~t+60s) is scaled proportionally by the conductor when this
      is shorter than 90s, so every chaos event still fires within the
      window.
    * `DEMO_FOREVER=1` — ignore `DEMO_DURATION` and run until the process
      receives an interrupt (Ctrl-C); the scoreboard is still measured
      and printed on interrupt, never skipped.
    * `DEMO_HEADLESS=1` — force append-only narration lines instead of an
      ANSI cursor-home redraw, even when stdout is a TTY. Non-TTY stdout
      (piped output, CI logs) is auto-detected as headless without this
      flag.

  ## Output

  Prints exactly one machine-parseable line:

      scoreboard runs_succeeded=<n> runs_failed=<n> duplicate_acquisitions=<n> controller_failovers=<n> failover_gap_ms=<n> gateway_failovers=<n> rehomed_runners=<n> archive_gaps=<n> cache_hits=<n>

  every value taken from the post-run verification pass, never from
  in-process director counters (see `SimRunner.Scene.Scoreboard`).

  Exits non-zero (via `Mix.raise/1`) when the measured scoreboard shows
  `runs_failed > 0`, `duplicate_acquisitions > 0`, `archive_gaps > 0`, or
  no controller failover was observed even though the timeline scheduled
  one — the same invariant rules `SimRunner.Scene.SceneRunner` enforces
  on itself.
  """

  use Mix.Task

  alias SimRunner.Scene.SceneRunner
  alias SimRunner.Scene.Scoreboard

  @default_duration_s 90

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    scoreboard = SceneRunner.run(scene_opts())

    IO.puts(summary_line(scoreboard))

    check!(scoreboard)

    # The scoreboard line above is the one contract every caller of this
    # task relies on, and it MUST have reached a piped stdout before the
    # OS process exits. Simply returning from `run/1` leaves the exit
    # path to whatever implicit shutdown the surrounding `mix` invocation
    # performs, which is not something this task controls or can rely on
    # to drain output first. `System.stop/1` performs an orderly shutdown
    # — stopping applications and closing every port (which flushes any
    # output still in flight) — before it halts, so drive the exit
    # through it explicitly instead of leaving it to chance. `System.stop/1`
    # itself returns immediately (the shutdown runs in the background), so
    # block here — not with a timed sleep, but with an unconditional
    # `receive` — until the VM the stop already kicked off actually
    # terminates the process.
    System.stop(0)

    receive do
    end
  end

  # -- environment -> scene options --------------------------------------

  @spec scene_opts() :: %{duration_s: pos_integer(), forever?: boolean(), headless?: boolean()}
  defp scene_opts do
    %{
      duration_s: duration_s(),
      forever?: forever?(),
      headless?: headless?()
    }
  end

  @spec duration_s() :: pos_integer()
  defp duration_s do
    case System.get_env("DEMO_DURATION") do
      nil ->
        @default_duration_s

      raw ->
        case Integer.parse(raw) do
          {value, _rest} when value > 0 -> value
          _other -> @default_duration_s
        end
    end
  end

  @spec forever?() :: boolean()
  defp forever?, do: System.get_env("DEMO_FOREVER") in ["1", "true"]

  @spec headless?() :: boolean()
  defp headless?, do: env_headless?() or not tty?()

  @spec env_headless?() :: boolean()
  defp env_headless?, do: System.get_env("DEMO_HEADLESS") in ["1", "true"]

  # stdout is a TTY only when the group leader can report a column width;
  # a pipe, file redirect, or non-interactive CI log answers `:enotsup`.
  @spec tty?() :: boolean()
  defp tty?, do: match?({:ok, _columns}, :io.columns())

  # -- output -------------------------------------------------------------

  @spec summary_line(Scoreboard.t()) :: String.t()
  defp summary_line(%Scoreboard{} = scoreboard) do
    "scoreboard " <>
      "runs_succeeded=#{scoreboard.runs_succeeded} " <>
      "runs_failed=#{scoreboard.runs_failed} " <>
      "duplicate_acquisitions=#{scoreboard.duplicate_acquisitions} " <>
      "controller_failovers=#{scoreboard.controller_failovers} " <>
      "failover_gap_ms=#{scoreboard.controller_failover_gap_ms} " <>
      "gateway_failovers=#{scoreboard.gateway_failovers} " <>
      "rehomed_runners=#{scoreboard.rehomed_runners} " <>
      "archive_gaps=#{scoreboard.archive_gaps} " <>
      "cache_hits=#{scoreboard.cache_hits}"
  end

  @spec check!(Scoreboard.t()) :: :ok
  defp check!(%Scoreboard{runs_failed: runs_failed}) when runs_failed > 0 do
    Mix.raise("demo failed: runs_failed=#{runs_failed}, expected 0")
  end

  defp check!(%Scoreboard{duplicate_acquisitions: duplicate_acquisitions})
       when duplicate_acquisitions > 0 do
    Mix.raise("demo failed: duplicate_acquisitions=#{duplicate_acquisitions}, expected 0")
  end

  defp check!(%Scoreboard{archive_gaps: archive_gaps}) when archive_gaps > 0 do
    Mix.raise("demo failed: archive_gaps=#{archive_gaps}, expected 0")
  end

  defp check!(%Scoreboard{controller_failovers: controller_failovers})
       when controller_failovers == 0 do
    Mix.raise(
      "demo failed: controller_failovers=0, expected at least 1 (the default timeline schedules a KillLeader event)"
    )
  end

  defp check!(_scoreboard), do: :ok
end
