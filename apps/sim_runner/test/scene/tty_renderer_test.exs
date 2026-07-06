defmodule SimRunner.Scene.TtyRendererTest do
  use ExUnit.Case, async: true

  alias SimRunner.Scene.Snapshot
  alias SimRunner.Scene.TtyRenderer

  defp snapshot!(fields \\ %{}) do
    {:ok, snapshot} = Snapshot.new(fields)
    snapshot
  end

  describe "render/5 in :tty mode" do
    test "emits a cursor-home + clear-screen redraw" do
      frame = TtyRenderer.render(snapshot!(), [], 0, 60_000, :tty)

      assert String.starts_with?(frame, IO.ANSI.home() <> IO.ANSI.clear())
    end

    test "is a pure function of its inputs — same in, same out" do
      snapshot =
        snapshot!(%{done: 1, queued: 2, running: 1, leased: 0, runs: [%{"phase" => "Running"}]})

      frame_a = TtyRenderer.render(snapshot, ["hello"], 1_000, 60_000, :tty)
      frame_b = TtyRenderer.render(snapshot, ["hello"], 1_000, 60_000, :tty)

      assert frame_a == frame_b
    end

    test "renders a progress bar sized to done/total runs" do
      snapshot = snapshot!(%{done: 2, queued: 1, running: 1, leased: 0})

      frame = TtyRenderer.render(snapshot, [], 0, 60_000, :tty)

      assert frame =~ "runs ["
      assert frame =~ "2/4"
    end

    test "falls back to a total of at least 1 run when nothing is observed yet" do
      frame = TtyRenderer.render(snapshot!(), [], 0, 60_000, :tty)

      assert frame =~ "0/1"
      assert frame =~ "runs: (none observed yet)"
    end

    test "renders one phase-glyph line per observed run" do
      snapshot =
        snapshot!(%{
          runs: [
            %{"name" => "run-a", "phase" => "Running"},
            %{"name" => "run-b", "phase" => "Succeeded"},
            %{"name" => "run-c", "phase" => "Failed"},
            %{"name" => "run-d", "phase" => "Queued"},
            %{"name" => "run-e", "phase" => "SomeWeirdPhase"}
          ]
        })

      frame = TtyRenderer.render(snapshot, [], 0, 60_000, :tty)

      assert frame =~ "> run-a [Running]"
      assert frame =~ "+ run-b [Succeeded]"
      assert frame =~ "x run-c [Failed]"
      assert frame =~ "o run-d [Queued]"
      assert frame =~ "? run-e [SomeWeirdPhase]"
    end

    test "falls back to the run's id when it has no name" do
      snapshot = snapshot!(%{runs: [%{"id" => "wfr-123", "phase" => "Queued"}]})

      frame = TtyRenderer.render(snapshot, [], 0, 60_000, :tty)

      assert frame =~ "o wfr-123 [Queued]"
    end

    test "includes the counters block" do
      snapshot =
        snapshot!(%{
          acquisitions: 12,
          duplicate_acquisitions: 1,
          cache_hits: 5,
          cache_misses: 2,
          chunk_count: 40,
          leader: "controller-a",
          lease_remaining_s: 9,
          gateways: [%{"id" => "gw-1"}, %{"id" => "gw-2"}],
          failovers: [%{"kind" => "controller"}]
        })

      frame = TtyRenderer.render(snapshot, [], 0, 60_000, :tty)

      assert frame =~ "leader=controller-a leaseRemainingS=9"
      assert frame =~ "acquisitions=12 duplicateAcquisitions=1"
      assert frame =~ "cacheHits=5 cacheMisses=2 chunkCount=40"
      assert frame =~ "gateways=2 failovers=1"
    end

    test "shows (none) for an empty leader" do
      frame = TtyRenderer.render(snapshot!(%{leader: ""}), [], 0, 60_000, :tty)

      assert frame =~ "leader=(none)"
    end

    test "shows only the last ~6 narration lines" do
      lines = for i <- 1..10, do: "line #{i}"

      frame = TtyRenderer.render(snapshot!(), lines, 0, 60_000, :tty)

      refute frame =~ "line 4"
      assert frame =~ "line 5"
      assert frame =~ "line 10"
    end

    test "shows a placeholder when there is no narration yet" do
      frame = TtyRenderer.render(snapshot!(), [], 0, 60_000, :tty)

      assert frame =~ "(no narration yet)"
    end

    test "formats elapsed and duration as mm:ss" do
      frame = TtyRenderer.render(snapshot!(), [], 65_000, 125_000, :tty)

      assert frame =~ "t+01m05s / 02m05s"
    end

    test "defaults to :tty mode when no mode is given" do
      frame = TtyRenderer.render(snapshot!(), [], 0, 60_000)

      assert String.starts_with?(frame, IO.ANSI.home())
    end
  end

  describe "render/5 in :headless mode" do
    test "emits no ANSI control codes" do
      frame = TtyRenderer.render(snapshot!(), ["hello", "world"], 1_000, 60_000, :headless)

      refute frame =~ IO.ANSI.home()
      refute frame =~ IO.ANSI.clear()
    end

    test "emits exactly the narration lines it is given, each on its own line" do
      frame = TtyRenderer.render(snapshot!(), ["first", "second"], 1_000, 60_000, :headless)

      assert frame == "[t+00m01s] first\n[t+00m01s] second"
    end

    test "renders an empty string when given no new narration lines" do
      frame = TtyRenderer.render(snapshot!(), [], 1_000, 60_000, :headless)

      assert frame == ""
    end

    test "is a pure function of its inputs — same in, same out" do
      snapshot = snapshot!(%{done: 3})

      frame_a = TtyRenderer.render(snapshot, ["only new line"], 2_000, 60_000, :headless)
      frame_b = TtyRenderer.render(snapshot, ["only new line"], 2_000, 60_000, :headless)

      assert frame_a == frame_b
    end
  end

  describe "detect_mode/2" do
    test "defaults to :tty when nothing opts out and output is a real tty" do
      assert TtyRenderer.detect_mode(%{}, true) == :tty
    end

    test "degrades to :headless when output is not a tty" do
      assert TtyRenderer.detect_mode(%{}, false) == :headless
    end

    test "degrades to :headless when DEMO_HEADLESS is set to a truthy value" do
      assert TtyRenderer.detect_mode(%{"DEMO_HEADLESS" => "1"}, true) == :headless
    end

    test "degrades to :headless when NO_COLOR is set to a truthy value" do
      assert TtyRenderer.detect_mode(%{"NO_COLOR" => "1"}, true) == :headless
    end

    test "treats DEMO_HEADLESS=0 and DEMO_HEADLESS=false as not set" do
      assert TtyRenderer.detect_mode(%{"DEMO_HEADLESS" => "0"}, true) == :tty
      assert TtyRenderer.detect_mode(%{"DEMO_HEADLESS" => "false"}, true) == :tty
    end

    test "treats an empty string as not set" do
      assert TtyRenderer.detect_mode(%{"DEMO_HEADLESS" => "", "NO_COLOR" => ""}, true) == :tty
    end
  end
end
