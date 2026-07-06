defmodule SimRunner.Scene.TtyRenderer do
  @moduledoc """
  Pure rendering of a `SimRunner.Scene.Snapshot` reading (plus recent
  narration lines, elapsed time, and total scene duration) into a single
  frame string, in one of two modes:

    * `:tty` — a fixed-layout ANSI frame: a cursor-home + clear-screen
      redraw, an overall run progress bar, one phase-glyph line per
      observed `WorkflowRun`, a counters block (acquisitions, cache
      hits/misses, chunk count, leader, lease remaining, gateway/failover
      counts), and the last ~6 narration lines.
    * `:headless` — no ANSI control codes at all: every line supplied in
      `narration_lines` is emitted as a plain, timestamped, append-only
      line, because a CI log or a non-interactive pipe cannot redraw in
      place and must never try to.

  `render/5` is a pure function: the same `(snapshot, narration_lines,
  elapsed_ms, duration_ms, mode)` in always produces the same string out.
  It knows nothing about `stdout`, `IO.puts/1`, environment variables, or
  any process state, and it never itself decides which mode to use — that
  degradation decision (is this actually a TTY? did the operator set
  `NO_COLOR` or `DEMO_HEADLESS`?) lives entirely in `detect_mode/2`, a
  separate, explicitly impure edge function, so the rendering core stays
  trivially pure and testable and the mode decision stays independently
  inspectable.

  "Only NEW narration/state-change lines" in headless mode is a calling
  convention, not hidden state inside this module: `render/5` never tracks
  history between calls (there is no history to reconstruct after a crash,
  matching this project's no-side-channel-state invariant) — it renders
  exactly the `narration_lines` list it is given, every time, in whichever
  mode it is told to use. A caller that wants append-only headless output
  simply passes only the lines that are new since its own previous call;
  a caller redrawing a TTY frame passes the recent window it wants shown.
  """

  alias SimRunner.Scene.Snapshot

  @type mode :: :tty | :headless

  @tty_narration_window 6
  @progress_bar_width 24

  @doc """
  Renders one frame for `snapshot` at `elapsed_ms` of `duration_ms`.

  `narration_lines` should be:

    * in `:tty` mode, the *recent* narration lines to show in the fixed
      "last ~#{@tty_narration_window}" panel — only the final
      #{@tty_narration_window} entries are kept; pass more and this
      function truncates, pass fewer and the panel simply shows fewer
      lines;
    * in `:headless` mode, only the lines that are *new* since the
      caller's previous frame — each is emitted once, appended, and never
      redrawn.

  `elapsed_ms` and `duration_ms` must both be non-negative integers
  (wall-clock milliseconds since the scene started, and the scene's
  configured total duration). `mode` defaults to `:tty`; pass `:headless`
  explicitly (see `detect_mode/2`) to get plain append-only output.
  """
  @spec render(Snapshot.t(), [String.t()], non_neg_integer(), non_neg_integer(), mode()) ::
          String.t()
  def render(snapshot, narration_lines, elapsed_ms, duration_ms, mode \\ :tty)

  def render(%Snapshot{} = snapshot, narration_lines, elapsed_ms, duration_ms, :tty)
      when is_list(narration_lines) and is_integer(elapsed_ms) and elapsed_ms >= 0 and
             is_integer(duration_ms) and duration_ms >= 0 do
    render_tty_frame(snapshot, narration_lines, elapsed_ms, duration_ms)
  end

  def render(%Snapshot{}, narration_lines, elapsed_ms, duration_ms, :headless)
      when is_list(narration_lines) and is_integer(elapsed_ms) and elapsed_ms >= 0 and
             is_integer(duration_ms) and duration_ms >= 0 do
    render_headless_lines(narration_lines, elapsed_ms)
  end

  @doc """
  Decides which mode a caller should render in, given the environment
  variables that opt a run into headless output (`DEMO_HEADLESS`,
  `NO_COLOR`) and whether output is actually attached to a TTY.

  This is the impure edge of the module: called with no arguments it
  consults the real process environment (`System.get_env/0`) and the real
  terminal (`IO.ANSI.enabled?/0`) every time. Both are accepted as
  arguments purely so callers — and this module's own tests — can supply
  fixed values instead of depending on the process they happen to run in.

  Degrades to `:headless` whenever `DEMO_HEADLESS` or `NO_COLOR` is set to
  a truthy value (anything other than unset, `""`, `"0"`, or `"false"`),
  or whenever `tty?` is `false`; otherwise renders in `:tty` mode.
  """
  @spec detect_mode(%{optional(String.t()) => String.t()}, boolean()) :: mode()
  def detect_mode(env \\ System.get_env(), tty? \\ IO.ANSI.enabled?()) do
    cond do
      truthy_env?(env, "DEMO_HEADLESS") -> :headless
      truthy_env?(env, "NO_COLOR") -> :headless
      not tty? -> :headless
      true -> :tty
    end
  end

  @spec truthy_env?(%{optional(String.t()) => String.t()}, String.t()) :: boolean()
  defp truthy_env?(env, key) do
    case Map.get(env, key) do
      nil -> false
      "" -> false
      "0" -> false
      "false" -> false
      _other -> true
    end
  end

  # -- TTY frame -------------------------------------------------------------

  @spec render_tty_frame(Snapshot.t(), [String.t()], non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp render_tty_frame(%Snapshot{} = snapshot, narration_lines, elapsed_ms, duration_ms) do
    [
      IO.ANSI.home() <> IO.ANSI.clear(),
      header_line(elapsed_ms, duration_ms),
      "",
      progress_line(snapshot),
      "",
      runs_block(snapshot),
      "",
      counters_block(snapshot),
      "",
      narration_block(narration_lines)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec header_line(non_neg_integer(), non_neg_integer()) :: String.t()
  defp header_line(elapsed_ms, duration_ms) do
    "== crest-ci demo scene  t+#{format_ms(elapsed_ms)} / #{format_ms(duration_ms)} =="
  end

  @spec progress_line(Snapshot.t()) :: String.t()
  defp progress_line(%Snapshot{} = snapshot) do
    total = total_runs(snapshot)
    "runs [#{progress_bar(snapshot.done, total)}] #{snapshot.done}/#{total}"
  end

  @spec total_runs(Snapshot.t()) :: pos_integer()
  defp total_runs(%Snapshot{} = snapshot) do
    from_list = length(snapshot.runs)
    from_counters = snapshot.done + snapshot.queued + snapshot.leased + snapshot.running
    Enum.max([from_list, from_counters, 1])
  end

  @spec progress_bar(non_neg_integer(), pos_integer()) :: String.t()
  defp progress_bar(done, total) do
    total = max(total, 1)

    filled =
      @progress_bar_width
      |> Kernel.*(done)
      |> div(total)
      |> min(@progress_bar_width)
      |> max(0)

    String.duplicate("#", filled) <> String.duplicate("-", @progress_bar_width - filled)
  end

  @spec runs_block(Snapshot.t()) :: [String.t()]
  defp runs_block(%Snapshot{runs: []}), do: ["runs: (none observed yet)"]

  defp runs_block(%Snapshot{runs: runs}) do
    Enum.map(runs, &run_line/1)
  end

  @spec run_line(map()) :: String.t()
  defp run_line(run) when is_map(run) do
    name = run_field(run, ["name", "id"], "?")
    phase = run_field(run, ["phase"], "Unknown")
    "  #{phase_glyph(phase)} #{name} [#{phase}]"
  end

  @spec run_field(map(), [String.t()], String.t()) :: String.t()
  defp run_field(run, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(run, key) || Map.get(run, safe_atom(key)) do
        nil -> nil
        value -> to_string(value)
      end
    end)
  end

  # Only ever called with our own small, fixed set of known field-name
  # literals ("name", "id", "phase") — never with attacker- or
  # resource-controlled strings — so this cannot be used to exhaust the
  # atom table.
  @spec safe_atom(String.t()) :: atom()
  defp safe_atom("name"), do: :name
  defp safe_atom("id"), do: :id
  defp safe_atom("phase"), do: :phase
  defp safe_atom(_other), do: :__tty_renderer_unknown_field__

  @spec phase_glyph(String.t()) :: String.t()
  defp phase_glyph(phase) when is_binary(phase) do
    case String.downcase(phase) do
      "queued" -> "o"
      "leased" -> "o"
      "running" -> ">"
      "succeeded" -> "+"
      "completed" -> "+"
      "done" -> "+"
      "failed" -> "x"
      "abandoned" -> "!"
      _other -> "?"
    end
  end

  @spec counters_block(Snapshot.t()) :: [String.t()]
  defp counters_block(%Snapshot{} = snapshot) do
    [
      "leader=#{leader_display(snapshot.leader)} leaseRemainingS=#{snapshot.lease_remaining_s}",
      "queued=#{snapshot.queued} leased=#{snapshot.leased} running=#{snapshot.running} done=#{snapshot.done}",
      "acquisitions=#{snapshot.acquisitions} duplicateAcquisitions=#{snapshot.duplicate_acquisitions}",
      "cacheHits=#{snapshot.cache_hits} cacheMisses=#{snapshot.cache_misses} chunkCount=#{snapshot.chunk_count}",
      "gateways=#{length(snapshot.gateways)} failovers=#{length(snapshot.failovers)}"
    ]
  end

  @spec leader_display(String.t()) :: String.t()
  defp leader_display(""), do: "(none)"
  defp leader_display(leader), do: leader

  @spec narration_block([String.t()]) :: [String.t()]
  defp narration_block(narration_lines) do
    case Enum.take(narration_lines, -@tty_narration_window) do
      [] -> ["(no narration yet)"]
      lines -> lines
    end
  end

  # -- Headless lines ---------------------------------------------------------

  @spec render_headless_lines([String.t()], non_neg_integer()) :: String.t()
  defp render_headless_lines(narration_lines, elapsed_ms) do
    narration_lines
    |> Enum.map(fn line -> "[t+#{format_ms(elapsed_ms)}] #{line}" end)
    |> Enum.join("\n")
  end

  @spec format_ms(non_neg_integer()) :: String.t()
  defp format_ms(ms) when is_integer(ms) and ms >= 0 do
    total_s = div(ms, 1000)
    m = div(total_s, 60)
    s = rem(total_s, 60)

    [pad2(m), "m", pad2(s), "s"]
    |> IO.iodata_to_binary()
  end

  @spec pad2(non_neg_integer()) :: String.t()
  defp pad2(n) when is_integer(n) and n >= 0 do
    n |> Integer.to_string() |> String.pad_leading(2, "0")
  end
end
