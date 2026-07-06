defmodule MockK8s.ResourceStore.Core do
  @moduledoc """
  Pure functional core of the mock Kubernetes resource store.

  Holds the canonical `State.t()` — a store-wide monotonic resourceVersion
  counter plus every stored object keyed by `{gvk, namespace, name}`. Every
  operation here is a pure function: a `State.t()` in, an updated
  `State.t()` (plus the written object and the `WatchEvent` it produced) or
  an `{:error, reason}` out. No process, no I/O, no side effects — the
  GenServer at `MockK8s.ResourceStore` is the only OTP edge that touches this
  module, per the project rule that pure functional cores stay separate from
  OTP processes.

  This module alone carries the aggregate's invariants:

    * resourceVersion increases strictly monotonically across ALL writes,
      regardless of kind.
    * `create/4` of an existing `{gvk, namespace, name}` fails with
      `:already_exists` and mutates nothing.
    * `update/4` and `patch_status/6` reject a stale expected resourceVersion
      with `:conflict` and mutate nothing.
    * `patch_status/6` replaces only the `status` subtree; `update/4` never
      touches `status`.
    * every successful write produces exactly one `WatchEvent`-shaped map
      stamped with the write's new resourceVersion.
    * `list/4` pagination enumerates every in-scope object exactly once
      across continuation pages.
  """

  defmodule State do
    @moduledoc """
    Resource store state: the monotonic resourceVersion counter and the
    object map it stamps. Immutable value — every `Core` function returns a
    new `State.t()` rather than mutating this one.
    """

    @type key :: {gvk :: String.t(), namespace :: String.t(), name :: String.t()}
    @type t :: %__MODULE__{
            current_resource_version: non_neg_integer(),
            objects: %{key() => map()}
          }

    defstruct current_resource_version: 0, objects: %{}
  end

  @type gvk :: String.t()
  @type namespace :: String.t()
  @type name :: String.t()
  @type object :: map()
  @type watch_event :: %{
          type: String.t(),
          object: object(),
          resource_version: String.t()
        }

  @doc "A fresh, empty store state — resourceVersion counter at zero."
  @spec new() :: State.t()
  def new, do: %State{}

  @doc """
  Create a new object under `{gvk, namespace, name}` (name read from
  `object["metadata"]["name"]`).

  Fails with `{:error, :already_exists}` if the key is already occupied —
  the store mutates nothing in that case.
  """
  @spec create(State.t(), gvk(), namespace(), object()) ::
          {:ok, State.t(), object(), watch_event()} | {:error, :already_exists | :invalid_object}
  def create(%State{} = state, gvk, namespace, object) when is_map(object) do
    with {:ok, name} <- fetch_name(object) do
      key = {gvk, namespace, name}

      if Map.has_key?(state.objects, key) do
        {:error, :already_exists}
      else
        base = stamp_identity(object, namespace, name)
        {new_state, stamped} = write(state, key, base)
        {:ok, new_state, stamped, event("ADDED", stamped, new_state.current_resource_version)}
      end
    end
  end

  @doc """
  Replace the spec + metadata of an existing object via optimistic
  concurrency: `object["metadata"]["resourceVersion"]` must match the
  currently stored resourceVersion or the write is rejected with
  `{:error, :conflict}` and nothing is mutated. The existing `status`
  subtree is always preserved — a plain update never touches status.
  """
  @spec update(State.t(), gvk(), namespace(), object()) ::
          {:ok, State.t(), object(), watch_event()}
          | {:error, :conflict | :not_found | :invalid_object}
  def update(%State{} = state, gvk, namespace, object) when is_map(object) do
    with {:ok, name} <- fetch_name(object),
         {:ok, expected_rv} <- fetch_resource_version(object) do
      key = {gvk, namespace, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {:error, :not_found}

        {:ok, current} ->
          if matches_resource_version?(current, expected_rv) do
            merged =
              object
              |> stamp_identity(namespace, name)
              |> Map.put("status", Map.get(current, "status"))

            {new_state, stamped} = write(state, key, merged)

            {:ok, new_state, stamped,
             event("MODIFIED", stamped, new_state.current_resource_version)}
          else
            {:error, :conflict}
          end
      end
    end
  end

  @doc """
  Replace only the `status` subtree of an existing object via optimistic
  concurrency on `expected_resource_version`. Spec and metadata (other than
  the freshly stamped resourceVersion) are left byte-identical. A mismatched
  `expected_resource_version` fails with `{:error, :conflict}` and mutates
  nothing.
  """
  @spec patch_status(State.t(), gvk(), namespace(), name(), map(), String.t()) ::
          {:ok, State.t(), object(), watch_event()} | {:error, :conflict | :not_found}
  def patch_status(%State{} = state, gvk, namespace, name, status, expected_resource_version)
      when is_map(status) do
    key = {gvk, namespace, name}

    case Map.fetch(state.objects, key) do
      :error ->
        {:error, :not_found}

      {:ok, current} ->
        if matches_resource_version?(current, expected_resource_version) do
          merged = Map.put(current, "status", status)
          {new_state, stamped} = write(state, key, merged)

          {:ok, new_state, stamped,
           event("MODIFIED", stamped, new_state.current_resource_version)}
        else
          {:error, :conflict}
        end
    end
  end

  @doc """
  Remove an object. Deletion is a write like any other: it still bumps the
  store-wide resourceVersion and emits exactly one `WatchEvent` (type
  `DELETED`) stamped with that new resourceVersion.
  """
  @spec delete(State.t(), gvk(), namespace(), name()) ::
          {:ok, State.t(), object(), watch_event()} | {:error, :not_found}
  def delete(%State{} = state, gvk, namespace, name) do
    key = {gvk, namespace, name}

    case Map.fetch(state.objects, key) do
      :error ->
        {:error, :not_found}

      {:ok, current} ->
        new_rv = state.current_resource_version + 1
        stamped = put_in(current, ["metadata", "resourceVersion"], to_string(new_rv))

        new_state = %State{
          current_resource_version: new_rv,
          objects: Map.delete(state.objects, key)
        }

        {:ok, new_state, stamped, event("DELETED", stamped, new_rv)}
    end
  end

  @doc "Fetch a single object by identity."
  @spec get(State.t(), gvk(), namespace(), name()) :: {:ok, object()} | {:error, :not_found}
  def get(%State{} = state, gvk, namespace, name) do
    case Map.fetch(state.objects, {gvk, namespace, name}) do
      {:ok, object} -> {:ok, object}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  List objects for `{gvk, namespace}`, ordered deterministically by name.

  `opts[:limit]` caps the page size; `opts[:continue]` resumes after the
  cursor returned as the third element of a previous call. Enumerating every
  page to exhaustion (until the returned continue token is `nil`) yields
  every in-scope object exactly once, even if unrelated objects are written
  in between — pages are cut strictly by name ordering within the objects
  currently in scope, never by a frozen snapshot that could skip or
  duplicate writes to *other* objects.
  """
  @spec list(State.t(), gvk(), namespace(), keyword()) :: {:ok, [object()], String.t() | nil}
  def list(%State{} = state, gvk, namespace, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    continue = Keyword.get(opts, :continue)

    in_scope =
      state.objects
      |> Enum.filter(fn {{k_gvk, k_ns, _name}, _object} -> k_gvk == gvk and k_ns == namespace end)
      |> Enum.sort_by(fn {{_gvk, _ns, name}, _object} -> name end)

    remaining =
      case continue do
        nil -> in_scope
        cursor -> Enum.drop_while(in_scope, fn {{_gvk, _ns, name}, _object} -> name <= cursor end)
      end

    {page, rest} =
      case limit do
        nil -> {remaining, []}
        n when is_integer(n) and n >= 0 -> Enum.split(remaining, n)
      end

    items = Enum.map(page, fn {_key, object} -> object end)

    continue_token =
      case {page, rest} do
        {[], _} -> nil
        {_page, []} -> nil
        {_page, _rest} -> page |> List.last() |> elem(0) |> elem(2)
      end

    {:ok, items, continue_token}
  end

  # -- helpers ---------------------------------------------------------

  defp fetch_name(object) do
    case get_in(object, ["metadata", "name"]) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :invalid_object}
    end
  end

  defp fetch_resource_version(object) do
    case get_in(object, ["metadata", "resourceVersion"]) do
      rv when is_binary(rv) -> {:ok, rv}
      rv when is_integer(rv) -> {:ok, to_string(rv)}
      _ -> {:error, :invalid_object}
    end
  end

  defp matches_resource_version?(current, expected) do
    to_string(get_in(current, ["metadata", "resourceVersion"])) == to_string(expected)
  end

  defp stamp_identity(object, namespace, name) do
    object
    |> Map.put_new("metadata", %{})
    |> update_in(["metadata"], fn meta ->
      meta
      |> Map.put("name", name)
      |> Map.put("namespace", namespace)
    end)
  end

  defp write(%State{} = state, key, object) do
    new_rv = state.current_resource_version + 1
    stamped = put_in(object, ["metadata", "resourceVersion"], to_string(new_rv))

    new_state = %State{
      current_resource_version: new_rv,
      objects: Map.put(state.objects, key, stamped)
    }

    {new_state, stamped}
  end

  defp event(type, object, resource_version) do
    %{type: type, object: object, resource_version: to_string(resource_version)}
  end
end
