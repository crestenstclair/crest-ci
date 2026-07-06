defmodule SimRunner.Scene.ChaosTimeline do
  @moduledoc """
  A pure, data-driven schedule of `SimRunner.Scene.SceneEvent`s and the pure
  function that decides which of them are due at a given elapsed offset.

  `ChaosTimeline` holds no process state and performs no side effects — it is
  the deterministic core that `ChaosDirector`/`ScenarioDirector` consult
  before acting through `port.Contract.KubeClient`. The default timeline is
  plain data (`default/0`), not code, specifically so tests can substitute a
  compressed timeline (events seconds instead of tens-of-seconds apart) and
  drive the same scheduling logic without waiting on real wall-clock time.

  The default timeline kills the controller leader ~t+20s, kills a gateway
  replica ~t+35s, and fires a run burst ~t+60s.

  ## Due-event semantics

  `due/3` is level-triggered and idempotent, mirroring the reconciliation
  discipline used everywhere else in this system: given the same
  `(timeline, elapsed_ms, already_fired)` inputs it always returns the same
  result, and an event already recorded in `already_fired` is never returned
  again no matter how many times `due/3` is replayed at or after its
  `at_ms`. Callers identify events by their position (index) in the
  `timeline` list, since `SceneEvent` itself carries no identity — the
  updated `already_fired` set returned alongside the due events is the
  caller's record to persist and pass back in on the next tick.
  """

  alias SimRunner.Scene.SceneEvent

  @type index :: non_neg_integer()
  @type fired :: MapSet.t(index())

  @default_timeline [
    %SceneEvent{at_ms: 20_000, kind: :kill_leader, detail: %{}},
    %SceneEvent{at_ms: 35_000, kind: :kill_gateway, detail: %{}},
    %SceneEvent{at_ms: 60_000, kind: :burst, detail: %{count: 10}}
  ]

  @doc """
  The default chaos/workload timeline: `KillLeader` ~t+20s, `KillGateway`
  ~t+35s, `Burst` ~t+60s. Plain data — callers may substitute any other
  list of `SceneEvent`s (e.g. a compressed timeline for fast tests) wherever
  a timeline is accepted.
  """
  @spec default() :: [SceneEvent.t()]
  def default, do: @default_timeline

  @doc """
  Given a `timeline`, the scene's current `elapsed_ms`, and the set of
  already-fired event indices, returns `{due_events, updated_already_fired}`.

  `due_events` contains every `SceneEvent` whose `at_ms` is at or before
  `elapsed_ms` and whose index is not already in `already_fired`, sorted by
  `at_ms` ascending (ties keep timeline order). `updated_already_fired` is
  `already_fired` unioned with the indices of the events just returned —
  the caller must persist and pass this back on the next call so those
  events are never re-fired.

  Pure and idempotent: calling `due/3` again with the same `elapsed_ms` and
  the previously returned `updated_already_fired` yields `{[], updated_already_fired}`
  unchanged, regardless of how many times or in what order it is replayed.
  """
  @spec due([SceneEvent.t()], non_neg_integer(), fired()) :: {[SceneEvent.t()], fired()}
  def due(timeline, elapsed_ms, already_fired \\ MapSet.new())

  def due(timeline, elapsed_ms, %MapSet{} = already_fired)
      when is_list(timeline) and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    due_indexed =
      timeline
      |> Enum.with_index()
      |> Enum.filter(fn {%SceneEvent{at_ms: at_ms}, index} ->
        at_ms <= elapsed_ms and not MapSet.member?(already_fired, index)
      end)
      |> Enum.sort_by(fn {%SceneEvent{at_ms: at_ms}, index} -> {at_ms, index} end)

    due_events = Enum.map(due_indexed, fn {event, _index} -> event end)

    updated_already_fired =
      Enum.reduce(due_indexed, already_fired, fn {_event, index}, acc ->
        MapSet.put(acc, index)
      end)

    {due_events, updated_already_fired}
  end
end
