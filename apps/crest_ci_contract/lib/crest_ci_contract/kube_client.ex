defmodule CrestCiContract.KubeClient do
  @moduledoc """
  The port every component (controller, gateway, sim-runner) uses to reach
  the Kubernetes API — the only interface through which controller and
  gateway coordinate. There is exactly one vocabulary for talking to the
  resource store; concrete adapters (e.g. a Req-based HTTP client speaking
  real Kubernetes REST conventions, or an in-memory test double) implement
  this behaviour and must be substitutable for one another (LSP): every
  callback returns the shapes declared here, nothing looser.

  Callers depend on distinguishing domain-meaningful errors from opaque
  transport failures:

    * `get/4` returns `{:error, :not_found}` when no object exists at that
      name — never conflated with a transport error.
    * `create/4` returns `{:error, :already_exists}` on a name collision.
      Combined with deterministic child naming, a 409 on create during a
      reconcile replay is a no-op, not a failure.
    * `update/4` and `patch_status/6` return `{:error, :conflict}` on a
      stale resource version. Conflicts are surfaced to the caller to retry
      against fresh state — an adapter must never silently force a write
      that lost optimistic concurrency.
    * `watch/5` returns `{:error, :gone}` when the requested
      `resource_version` has been compacted out of history, so callers can
      fall back to a fresh `list/4` and re-watch from its resource version.

  No callback here holds any state itself: a `conn` is an opaque handle
  supplied by the caller (constructed and owned by whatever composes the
  adapter), so this module has nothing to reconstruct after a crash — all
  authoritative state lives in the resource store on the other end of the
  connection.
  """

  @typedoc "Opaque connection/config handle owned by the caller; adapters define its shape."
  @type conn :: term()

  @typedoc "Group-Version-Kind identifying a Kubernetes resource type, e.g. {\"ci.crest.dev\", \"v1alpha1\", \"WorkflowRun\"}."
  @type gvk :: {group :: String.t(), version :: String.t(), kind :: String.t()}

  @type namespace :: String.t()
  @type name :: String.t()

  @typedoc "A decoded Kubernetes object: metadata/spec/status envelope as a map with string keys."
  @type object :: map()

  @typedoc "Opaque pagination token returned by list/4; nil when there are no further pages."
  @type continue_token :: String.t() | nil

  @typedoc "The etcd-semantics optimistic-concurrency token (Kubernetes metadata.resourceVersion)."
  @type resource_version :: String.t()

  @typedoc "Opaque handle representing a live watch, returned by watch/5 and used by callers to cancel it."
  @type watch_ref :: term()

  @typedoc "A single decoded watch stream event delivered to the watch callback."
  @type watch_event ::
          {:added, object()}
          | {:modified, object()}
          | {:deleted, object()}
          | {:bookmark, resource_version()}
          | {:error, term()}

  @typedoc "Invoked by the adapter for every event observed on the watch stream."
  @type watch_callback :: (watch_event() -> any())

  @typedoc "List options: at minimum a label selector and/or a continue token for pagination."
  @type list_opts :: keyword()

  @doc """
  Fetch a single object by name. Returns `{:error, :not_found}` when no
  object with that name exists in the namespace — distinguishable from any
  other error so callers can decide "absent" vs "broken" without inspecting
  opaque terms.
  """
  @callback get(conn(), gvk(), namespace(), name()) ::
              {:ok, object()} | {:error, :not_found | term()}

  @doc """
  List objects of a gvk in a namespace, optionally filtered/paginated via
  `opts`. Returns the page of objects plus a continue token (`nil` when
  exhausted).
  """
  @callback list(conn(), gvk(), namespace(), list_opts()) ::
              {:ok, [object()], continue_token()} | {:error, term()}

  @doc """
  Create an object. Returns `{:error, :already_exists}` when an object with
  the same deterministic name already exists in the namespace — callers
  rely on this to treat a 409 during reconcile replay as a no-op rather
  than an error to propagate.
  """
  @callback create(conn(), gvk(), namespace(), object()) ::
              {:ok, object()} | {:error, :already_exists | term()}

  @doc """
  Replace an object's spec/metadata. Returns `{:error, :conflict}` when the
  object's stored resourceVersion no longer matches what the caller last
  read (optimistic-concurrency CAS lost) — the adapter must never force
  the write in this case; the caller re-reads and retries.
  """
  @callback update(conn(), gvk(), namespace(), object()) ::
              {:ok, object()} | {:error, :conflict | term()}

  @doc """
  Patch only the status subresource, compare-and-swapped against
  `expected_resource_version`. Returns `{:error, :conflict}` when the
  live resourceVersion has moved past what was expected — this is the
  sole arbitration mechanism for RunnerJob lease/acquisition races.
  """
  @callback patch_status(
              conn(),
              gvk(),
              namespace(),
              name(),
              status :: map(),
              expected_resource_version :: resource_version()
            ) :: {:ok, object()} | {:error, :conflict | term()}

  @doc """
  Delete an object by name. Deleting an already-absent object is treated
  as success by callers performing idempotent cleanup; adapters return
  whatever the store reports, and reconcilers decide how to interpret it.
  """
  @callback delete(conn(), gvk(), namespace(), name()) :: :ok | {:error, term()}

  @doc """
  Start watching a gvk in a namespace from `from_resource_version`,
  invoking `callback` for every decoded event. Returns `{:error, :gone}`
  when `from_resource_version` has been compacted out of the store's
  history, so the caller can fall back to a fresh `list/4` and re-watch
  from its resourceVersion.
  """
  @callback watch(conn(), gvk(), namespace(), resource_version(), watch_callback()) ::
              {:ok, watch_ref()} | {:error, :gone | term()}
end
