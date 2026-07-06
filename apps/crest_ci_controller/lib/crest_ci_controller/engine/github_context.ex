defmodule CrestCiController.Engine.GithubContext do
  @moduledoc """
  The `github.*` expression context assembled from a workflow trigger
  event: `event_name`, `ref`, `sha`, `repository`, `actor`, and the raw
  `event` payload itself (the full webhook JSON body, kept intact so
  event-specific fields remain reachable via `github.event.*` property
  access in the `ExpressionEvaluator`).

  Pure value object: no I/O, no process state, no clock reads. Every
  field is either passed in directly or derived from the raw `event` map
  by `from_event/2` — identical `(event_name, event)` input always
  produces a byte-identical `GithubContext`, matching the engine's
  overall determinism invariant.

  `from_event/2` mirrors (a useful, C1-scoped subset of) how GitHub
  itself derives `ref`/`sha`/`repository`/`actor` from the raw webhook
  payload per event type — `push` and `pull_request` get their own
  mapping (the two triggers this slice's fixtures exercise); every other
  `event_name` falls back to the top-level `ref`/`sha` conventions shared
  by `workflow_dispatch`, `schedule`, `release`, and friends. Adding a
  new event-specific mapping only ever means adding another private
  clause here — this module has exactly one reason to change: how the
  `github.*` context is assembled from a trigger event.

  Serializes to/from the Kubernetes JSON wire shape (camelCase keys) via
  `to_wire/1` / `from_wire/1` — this context travels inside job messages
  the gateway serves to runners — and via `Jason.Encoder` for direct
  `Jason.encode!/1` calls. `to_expr_context/1` produces the plain,
  string-keyed map handed to the `ExpressionEvaluator` as the `"github"`
  branch of a job's evaluation context.
  """

  @enforce_keys [:actor, :event, :event_name, :ref, :repository, :sha]
  defstruct actor: nil,
            event: nil,
            event_name: nil,
            ref: nil,
            repository: nil,
            sha: nil

  @type t :: %__MODULE__{
          actor: String.t(),
          event: map(),
          event_name: String.t(),
          ref: String.t(),
          repository: String.t(),
          sha: String.t()
        }

  @doc """
  Builds a new `GithubContext` from field values (atom keys).

  `actor`, `event_name`, `ref`, `repository`, and `sha` must be binaries
  (empty allowed — some trigger events genuinely carry no actor, e.g. a
  cron `schedule` run). `event` must be a map (the raw webhook payload;
  `%{}` is accepted for synthetic/manual triggers with no payload body).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(fields) when is_map(fields) do
    with {:ok, actor} <- validate_binary(Map.get(fields, :actor), :invalid_actor),
         {:ok, event} <- validate_map(Map.get(fields, :event), :invalid_event),
         {:ok, event_name} <- validate_binary(Map.get(fields, :event_name), :invalid_event_name),
         {:ok, ref} <- validate_binary(Map.get(fields, :ref), :invalid_ref),
         {:ok, repository} <- validate_binary(Map.get(fields, :repository), :invalid_repository),
         {:ok, sha} <- validate_binary(Map.get(fields, :sha), :invalid_sha) do
      {:ok,
       %__MODULE__{
         actor: actor,
         event: event,
         event_name: event_name,
         ref: ref,
         repository: repository,
         sha: sha
       }}
    end
  end

  def new(other), do: {:error, {:invalid_github_context, other}}

  @doc """
  Assembles a `GithubContext` from a raw trigger event: the webhook
  `event_name` and the raw JSON `event` payload (string-keyed map, as
  delivered on the wire — never atom-keyed).

  Pure and deterministic: derives `ref`, `sha`, `repository`, and `actor`
  from the shape of `event` per the rules below, with no clock read, no
  randomness, and no environment access. Identical `(event_name, event)`
  input always yields a byte-identical `GithubContext`.

    * `"push"` — `ref` and `sha` come from the push payload's own
      `"ref"` / `"after"` (the resulting commit SHA, not the pre-push
      one); `actor` prefers `"pusher"."name"`, falling back to
      `"sender"."login"` when absent.
    * `"pull_request"` (and `"pull_request_target"`) — `ref` is GitHub's
      synthetic merge ref `refs/pull/<number>/merge`; `sha` is the PR's
      head commit (`"pull_request"."head"."sha"`); `actor` is
      `"sender"."login"`.
    * anything else (`"workflow_dispatch"`, `"schedule"`, `"release"`,
      and other event types this C1 slice does not special-case) — `ref`
      and `sha` come from the event's own top-level `"ref"` / `"sha"`
      when present (the convention these triggers share), defaulting to
      `""` when absent; `actor` is `"sender"."login"`.

  `repository` is always `"repository"."full_name"` off the event,
  defaulting to `""` when absent — every GitHub event carries the same
  repository shape regardless of trigger type.
  """
  @spec from_event(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def from_event(event_name, event) when is_binary(event_name) and is_map(event) do
    {ref, sha} = derive_ref_and_sha(event_name, event)

    new(%{
      actor: derive_actor(event_name, event),
      event: event,
      event_name: event_name,
      ref: ref,
      repository: dig(event, ["repository", "full_name"], ""),
      sha: sha
    })
  end

  def from_event(other_event_name, other_event),
    do: {:error, {:invalid_trigger_event, {other_event_name, other_event}}}

  @spec derive_ref_and_sha(String.t(), map()) :: {String.t(), String.t()}
  defp derive_ref_and_sha("push", event) do
    {dig(event, ["ref"], ""), dig(event, ["after"], "")}
  end

  defp derive_ref_and_sha(pull_request_event, event)
       when pull_request_event in ["pull_request", "pull_request_target"] do
    ref =
      case dig(event, ["number"], nil) do
        nil -> ""
        number -> "refs/pull/#{number}/merge"
      end

    {ref, dig(event, ["pull_request", "head", "sha"], "")}
  end

  defp derive_ref_and_sha(_other_event_name, event) do
    {dig(event, ["ref"], ""), dig(event, ["sha"], "")}
  end

  @spec derive_actor(String.t(), map()) :: String.t()
  defp derive_actor("push", event) do
    case dig(event, ["pusher", "name"], nil) do
      nil -> dig(event, ["sender", "login"], "")
      name -> name
    end
  end

  defp derive_actor(_other_event_name, event), do: dig(event, ["sender", "login"], "")

  @spec dig(map(), [String.t()], term()) :: term()
  defp dig(map, path, default) when is_map(map) and is_list(path) do
    case get_in(map, path) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Decodes a `GithubContext` from its Kubernetes JSON wire shape: a map
  with camelCase string keys (`actor`, `event`, `eventName`, `ref`,
  `repository`, `sha`).
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{} = wire) do
    new(%{
      actor: Map.get(wire, "actor", ""),
      event: Map.get(wire, "event", %{}),
      event_name: Map.get(wire, "eventName", ""),
      ref: Map.get(wire, "ref", ""),
      repository: Map.get(wire, "repository", ""),
      sha: Map.get(wire, "sha", "")
    })
  end

  def from_wire(other), do: {:error, {:invalid_github_context, other}}

  @doc "Encodes a `GithubContext` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = context) do
    %{
      "actor" => context.actor,
      "event" => context.event,
      "eventName" => context.event_name,
      "ref" => context.ref,
      "repository" => context.repository,
      "sha" => context.sha
    }
  end

  @doc """
  Produces the plain, string-keyed map handed to the
  `ExpressionEvaluator` as the `"github"` branch of a job's evaluation
  context, using GitHub's own `github.*` property names (`event_name`,
  not `eventName`) so `github.event_name`, `github.ref`, `github.sha`,
  `github.repository`, `github.actor`, and `github.event` property
  access resolve exactly as they do in real GitHub Actions expressions.
  """
  @spec to_expr_context(t()) :: %{optional(String.t()) => term()}
  def to_expr_context(%__MODULE__{} = context) do
    %{
      "actor" => context.actor,
      "event" => context.event,
      "event_name" => context.event_name,
      "ref" => context.ref,
      "repository" => context.repository,
      "sha" => context.sha
    }
  end

  @spec validate_binary(term(), atom()) :: {:ok, String.t()} | {:error, atom()}
  defp validate_binary(value, _error) when is_binary(value), do: {:ok, value}
  defp validate_binary(_value, error), do: {:error, error}

  @spec validate_map(term(), atom()) :: {:ok, map()} | {:error, atom()}
  defp validate_map(value, _error) when is_map(value), do: {:ok, value}
  defp validate_map(_value, error), do: {:error, error}
end

defimpl Jason.Encoder, for: CrestCiController.Engine.GithubContext do
  def encode(context, opts) do
    context
    |> CrestCiController.Engine.GithubContext.to_wire()
    |> Jason.Encode.map(opts)
  end
end
