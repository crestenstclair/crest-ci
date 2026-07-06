defmodule SimRunner.Scene.Snapshot do
  @moduledoc """
  A single dashboard-model reading of the demo scene, derived ONLY from
  authoritative custom resources (`WorkflowRun`, `RunnerJob`, `Lease`, pods)
  and the outputs jobs record — never from any process-local counter that
  could diverge from what those resources say.

  This module is a pure value object: it knows the *shape* of a valid
  reading and how to move it across the wire. It has no opinion about how
  the numbers are computed (that is `SimRunner.Scene.StateSnapshotter`'s
  job, a domain service with exactly one reason to change: derivation
  logic) and no opinion about how a reading is drawn to a terminal (that is
  `SimRunner.Scene.TtyRenderer`'s job). Keeping those concerns in separate
  modules is what lets each be tested — and changed — independently.

  Field meanings:

    * `acquisitions` — total successful RunnerJob acquisitions observed
    * `cache_hits` / `cache_misses` — cache-step outcomes recorded in job
      outputs
    * `chunk_count` — log chunks ingested (post idempotent de-dup)
    * `done` — WorkflowRuns that have reached a terminal phase
    * `duplicate_acquisitions` — acquisition attempts that lost the
      RunnerJob status resourceVersion CAS, computed from RunnerJob status
      history, never incremented by observing a request in flight
    * `elapsed_ms` — wall-clock milliseconds since the scene started
    * `failovers` — a list of maps, one per observed failover event
      (controller or gateway), in occurrence order
    * `gateways` — a list of maps, one per gateway replica, describing its
      current observed state
    * `leader` — the id of the controller replica currently holding the
      coordination Lease, or `""` when no leader is currently observed
    * `lease_remaining_s` — seconds remaining before the coordination Lease
      expires; may be negative for a brief window between expiry and the
      next leader's renewal being observed
    * `leased` / `queued` / `running` — RunnerJob counts by phase bucket
    * `runs` — a list of maps, one per WorkflowRun, describing its current
      observed state

  Serializes to/from the JSON wire shape (camelCase keys, exactly mirroring
  this resource's declared `state` shape) via `to_wire/1` / `from_wire/1`,
  and via `Jason.Encoder` for direct `Jason.encode!/1` calls.
  """

  @type t :: %__MODULE__{
          acquisitions: non_neg_integer(),
          cache_hits: non_neg_integer(),
          cache_misses: non_neg_integer(),
          chunk_count: non_neg_integer(),
          done: non_neg_integer(),
          duplicate_acquisitions: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          failovers: [map()],
          gateways: [map()],
          leader: String.t(),
          lease_remaining_s: integer(),
          leased: non_neg_integer(),
          queued: non_neg_integer(),
          running: non_neg_integer(),
          runs: [map()]
        }

  defstruct acquisitions: 0,
            cache_hits: 0,
            cache_misses: 0,
            chunk_count: 0,
            done: 0,
            duplicate_acquisitions: 0,
            elapsed_ms: 0,
            failovers: [],
            gateways: [],
            leader: "",
            lease_remaining_s: 0,
            leased: 0,
            queued: 0,
            running: 0,
            runs: []

  @non_negative_int_fields [
    :acquisitions,
    :cache_hits,
    :cache_misses,
    :chunk_count,
    :done,
    :duplicate_acquisitions,
    :elapsed_ms,
    :leased,
    :queued,
    :running
  ]

  @list_of_map_fields [:failovers, :gateways, :runs]

  @doc """
  Builds a new `Snapshot` from field values (atom keys), validating that:

    * every counter field is a non-negative integer
    * `lease_remaining_s` is an integer (may be negative)
    * `leader` is a string
    * `failovers`, `gateways`, and `runs` are each a list of maps

  Any field omitted from `fields` defaults to its struct default (`0`,
  `""`, or `[]`). Returns `{:error, {:invalid_field, field, value}}` for
  the first violation found, in declaration order, so callers get a
  precise, deterministic diagnosis rather than a generic pattern-match
  failure.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_field, atom(), term()}}
  def new(fields) when is_map(fields) do
    with :ok <- validate_non_negative_ints(fields),
         :ok <- validate_lease_remaining(fields),
         :ok <- validate_leader(fields),
         :ok <- validate_lists_of_maps(fields) do
      {:ok,
       %__MODULE__{
         acquisitions: Map.get(fields, :acquisitions, 0),
         cache_hits: Map.get(fields, :cache_hits, 0),
         cache_misses: Map.get(fields, :cache_misses, 0),
         chunk_count: Map.get(fields, :chunk_count, 0),
         done: Map.get(fields, :done, 0),
         duplicate_acquisitions: Map.get(fields, :duplicate_acquisitions, 0),
         elapsed_ms: Map.get(fields, :elapsed_ms, 0),
         failovers: Map.get(fields, :failovers, []),
         gateways: Map.get(fields, :gateways, []),
         leader: Map.get(fields, :leader, ""),
         lease_remaining_s: Map.get(fields, :lease_remaining_s, 0),
         leased: Map.get(fields, :leased, 0),
         queued: Map.get(fields, :queued, 0),
         running: Map.get(fields, :running, 0),
         runs: Map.get(fields, :runs, [])
       }}
    end
  end

  @doc """
  Decodes a `Snapshot` from its JSON wire shape: a map with camelCase
  string keys, exactly mirroring this resource's declared `state` shape
  (e.g. as produced by `StateSnapshotter` or read back from a persisted
  demo transcript). Applies the same validation as `new/1`.
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, {:invalid_field, atom(), term()}}
  def from_wire(%{} = wire) do
    new(%{
      acquisitions: Map.get(wire, "acquisitions", 0),
      cache_hits: Map.get(wire, "cacheHits", 0),
      cache_misses: Map.get(wire, "cacheMisses", 0),
      chunk_count: Map.get(wire, "chunkCount", 0),
      done: Map.get(wire, "done", 0),
      duplicate_acquisitions: Map.get(wire, "duplicateAcquisitions", 0),
      elapsed_ms: Map.get(wire, "elapsedMs", 0),
      failovers: Map.get(wire, "failovers", []),
      gateways: Map.get(wire, "gateways", []),
      leader: Map.get(wire, "leader", ""),
      lease_remaining_s: Map.get(wire, "leaseRemainingS", 0),
      leased: Map.get(wire, "leased", 0),
      queued: Map.get(wire, "queued", 0),
      running: Map.get(wire, "running", 0),
      runs: Map.get(wire, "runs", [])
    })
  end

  @doc "Encodes a `Snapshot` into its JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = snapshot) do
    %{
      "acquisitions" => snapshot.acquisitions,
      "cacheHits" => snapshot.cache_hits,
      "cacheMisses" => snapshot.cache_misses,
      "chunkCount" => snapshot.chunk_count,
      "done" => snapshot.done,
      "duplicateAcquisitions" => snapshot.duplicate_acquisitions,
      "elapsedMs" => snapshot.elapsed_ms,
      "failovers" => snapshot.failovers,
      "gateways" => snapshot.gateways,
      "leader" => snapshot.leader,
      "leaseRemainingS" => snapshot.lease_remaining_s,
      "leased" => snapshot.leased,
      "queued" => snapshot.queued,
      "running" => snapshot.running,
      "runs" => snapshot.runs
    }
  end

  @spec validate_non_negative_ints(map()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_non_negative_ints(fields) do
    Enum.reduce_while(@non_negative_int_fields, :ok, fn field, :ok ->
      case Map.get(fields, field, 0) do
        n when is_integer(n) and n >= 0 -> {:cont, :ok}
        other -> {:halt, {:error, {:invalid_field, field, other}}}
      end
    end)
  end

  @spec validate_lease_remaining(map()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_lease_remaining(fields) do
    case Map.get(fields, :lease_remaining_s, 0) do
      n when is_integer(n) -> :ok
      other -> {:error, {:invalid_field, :lease_remaining_s, other}}
    end
  end

  @spec validate_leader(map()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_leader(fields) do
    case Map.get(fields, :leader, "") do
      s when is_binary(s) -> :ok
      other -> {:error, {:invalid_field, :leader, other}}
    end
  end

  @spec validate_lists_of_maps(map()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_lists_of_maps(fields) do
    Enum.reduce_while(@list_of_map_fields, :ok, fn field, :ok ->
      case Map.get(fields, field, []) do
        list when is_list(list) ->
          if Enum.all?(list, &is_map/1) do
            {:cont, :ok}
          else
            {:halt, {:error, {:invalid_field, field, list}}}
          end

        other ->
          {:halt, {:error, {:invalid_field, field, other}}}
      end
    end)
  end
end

defimpl Jason.Encoder, for: SimRunner.Scene.Snapshot do
  def encode(snapshot, opts) do
    snapshot
    |> SimRunner.Scene.Snapshot.to_wire()
    |> Jason.Encode.map(opts)
  end
end
