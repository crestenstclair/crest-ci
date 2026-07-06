defmodule SimRunner.Scene.SceneEvent do
  @moduledoc """
  A single entry in the Scene's scripted chaos/workload timeline: at an
  elapsed offset (`at_ms`), do a thing (`kind`) with some free-form
  parameters (`detail`), and narrate it.

  `SceneEvent` is a plain, immutable value object with no independent
  identity or lifecycle — it carries no reference to any Kubernetes custom
  resource and is never itself persisted. `ChaosTimeline` holds a list of
  these (the default timeline: `KillLeader` ~t+20s, `KillGateway` ~t+35s,
  `Burst` ~t+60s) and `ChaosDirector`/`ScenarioDirector` execute whichever
  ones are due, each acting only through `port.Contract.KubeClient` against
  authoritative custom resources — the event itself carries no process
  handles or side-channel state.

  `kind` is restricted to a closed set of scene actions:

    * `:kill_leader`  — kill the current controller leader's supervisor
    * `:kill_gateway` — kill one gateway replica
    * `:burst`        — submit N workflow runs at once
    * `:submit`       — submit a single workflow run
    * `:narrate`      — emit a narration banner with no side effect
  """

  @type kind :: :kill_leader | :kill_gateway | :burst | :submit | :narrate

  @type t :: %__MODULE__{
          at_ms: non_neg_integer(),
          kind: kind(),
          detail: map()
        }

  @enforce_keys [:at_ms, :kind]
  defstruct at_ms: nil, kind: nil, detail: %{}

  @kinds [:kill_leader, :kill_gateway, :burst, :submit, :narrate]

  @wire_kinds %{
    "KillLeader" => :kill_leader,
    "KillGateway" => :kill_gateway,
    "Burst" => :burst,
    "Submit" => :submit,
    "Narrate" => :narrate
  }

  @kind_wire for {wire, kind} <- @wire_kinds, into: %{}, do: {kind, wire}

  @doc "The closed set of valid `kind` atoms, for callers building timelines."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Builds a new `SceneEvent` from field values (atom keys: `:at_ms`, `:kind`,
  optionally `:detail`).

  `at_ms` must be a non-negative integer (an elapsed offset from scene
  start) and `kind` must be one of the closed set of scene actions —
  anything else is rejected rather than defaulted, since an event the
  timeline cannot act on is not a valid event. `detail` defaults to `%{}`
  and must be a map when supplied.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_scene_event}
  def new(fields) when is_map(fields) do
    with {:ok, at_ms} <- fetch_at_ms(fields),
         {:ok, kind} <- fetch_kind(fields),
         {:ok, detail} <- fetch_detail(fields) do
      {:ok, %__MODULE__{at_ms: at_ms, kind: kind, detail: detail}}
    end
  end

  def new(_fields), do: {:error, :invalid_scene_event}

  @doc """
  Decodes a `SceneEvent` from its wire shape: a map with camelCase string
  keys `"atMs"`, `"kind"` (one of `"KillLeader"`, `"KillGateway"`,
  `"Burst"`, `"Submit"`, `"Narrate"`), and optionally `"detail"`.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_scene_event}
  def from_wire(%{} = wire) do
    kind =
      case Map.get(wire, "kind") do
        wire_kind when is_binary(wire_kind) -> Map.get(@wire_kinds, wire_kind, wire_kind)
        other -> other
      end

    new(%{
      at_ms: Map.get(wire, "atMs"),
      kind: kind,
      detail: Map.get(wire, "detail", %{})
    })
  end

  def from_wire(_wire), do: {:error, :invalid_scene_event}

  @doc "Encodes a `SceneEvent` into its wire shape (camelCase keys, `kind` as its PascalCase name)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = event) do
    %{
      "atMs" => event.at_ms,
      "kind" => Map.fetch!(@kind_wire, event.kind),
      "detail" => event.detail
    }
  end

  @spec fetch_at_ms(map()) :: {:ok, non_neg_integer()} | {:error, :invalid_scene_event}
  defp fetch_at_ms(fields) do
    case Map.get(fields, :at_ms) do
      at_ms when is_integer(at_ms) and at_ms >= 0 -> {:ok, at_ms}
      _other -> {:error, :invalid_scene_event}
    end
  end

  @spec fetch_kind(map()) :: {:ok, kind()} | {:error, :invalid_scene_event}
  defp fetch_kind(fields) do
    case Map.get(fields, :kind) do
      kind when kind in @kinds -> {:ok, kind}
      _other -> {:error, :invalid_scene_event}
    end
  end

  @spec fetch_detail(map()) :: {:ok, map()} | {:error, :invalid_scene_event}
  defp fetch_detail(fields) do
    case Map.get(fields, :detail, %{}) do
      detail when is_map(detail) -> {:ok, detail}
      _other -> {:error, :invalid_scene_event}
    end
  end
end

defimpl Jason.Encoder, for: SimRunner.Scene.SceneEvent do
  def encode(event, opts) do
    event
    |> SimRunner.Scene.SceneEvent.to_wire()
    |> Jason.Encode.map(opts)
  end
end
