defmodule CrestCiContract.Test.FakeKubeClient do
  @moduledoc """
  Test-only reference adapter for `CrestCiContract.KubeClient`.

  Backs the port with an `Agent` so `kube_client_test.exs` can exercise the
  error-classification contract (`:not_found`, `:already_exists`,
  `:conflict`, `:gone`) end-to-end without a real Kubernetes API server.
  This module is test fixture code, not a production component — the
  project invariant against ETS/Agent-as-source-of-truth applies to
  controller/gateway coordination state, not to a disposable per-test
  double standing in for "the cluster".

  `conn` for this adapter is the Agent pid returned by `start_link/0`.

  ## Compaction

  Real Kubernetes/etcd periodically compacts old revisions out of history
  so the keyspace does not grow unbounded — any `watch` resuming from a
  compacted-away resourceVersion gets `{:error, :gone}`. Callers only ever
  observe that through the declared contract surface (there is no separate
  "compact" callback), so this fake derives compaction automatically from
  ordinary writes: every successful `create/4`, `update/4`, or
  `patch_status/6` advances the resourceVersion counter, and only the most
  recent `@retained_revisions` revisions stay watchable — older ones age
  out on their own, exactly as they would against a real cluster.
  `compact_before/2` remains available as an explicit override for tests
  that want to force the boundary directly without performing a pile of
  writes first.
  """

  @behaviour CrestCiContract.KubeClient

  # How many of the most-recent resourceVersions stay live/watchable.
  # Anything older ages out automatically as ordinary writes advance rv.
  @retained_revisions 2

  @doc "Start a fresh, empty fake store. The returned pid is the `conn` for every callback."
  @spec start_link() :: {:ok, pid()}
  def start_link do
    Agent.start_link(fn -> %{objects: %{}, rv: 0, compacted_before: nil} end)
  end

  @doc "Mark every resourceVersion below `rv` as compacted away, so watch/5 from an earlier rv returns {:error, :gone}."
  @spec compact_before(pid(), non_neg_integer()) :: :ok
  def compact_before(conn, rv) do
    Agent.update(conn, fn state ->
      %{state | compacted_before: max(state.compacted_before || 0, rv)}
    end)
  end

  @impl true
  def get(conn, gvk, namespace, name) do
    Agent.get(conn, fn state ->
      case Map.fetch(state.objects, {gvk, namespace, name}) do
        {:ok, object} -> {:ok, object}
        :error -> {:error, :not_found}
      end
    end)
  end

  @impl true
  def list(conn, gvk, namespace, _opts) do
    Agent.get(conn, fn state ->
      objects =
        state.objects
        |> Enum.filter(fn {{o_gvk, o_ns, _name}, _obj} -> o_gvk == gvk and o_ns == namespace end)
        |> Enum.map(fn {_key, object} -> object end)

      {:ok, objects, nil}
    end)
  end

  @impl true
  def create(conn, gvk, namespace, object) do
    name = fetch_name(object)

    Agent.get_and_update(conn, fn state ->
      key = {gvk, namespace, name}

      if Map.has_key?(state.objects, key) do
        {{:error, :already_exists}, state}
      else
        next_rv = state.rv + 1
        stored = put_resource_version(object, next_rv)

        new_state = %{
          state
          | objects: Map.put(state.objects, key, stored),
            rv: next_rv,
            compacted_before: advance_compaction(state.compacted_before, next_rv)
        }

        {{:ok, stored}, new_state}
      end
    end)
  end

  @impl true
  def update(conn, gvk, namespace, object) do
    name = fetch_name(object)
    caller_rv = fetch_resource_version(object)

    Agent.get_and_update(conn, fn state ->
      key = {gvk, namespace, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, current} ->
          if fetch_resource_version(current) != caller_rv do
            {{:error, :conflict}, state}
          else
            next_rv = state.rv + 1
            stored = put_resource_version(object, next_rv)

            new_state = %{
              state
              | objects: Map.put(state.objects, key, stored),
                rv: next_rv,
                compacted_before: advance_compaction(state.compacted_before, next_rv)
            }

            {{:ok, stored}, new_state}
          end
      end
    end)
  end

  @impl true
  def patch_status(conn, gvk, namespace, name, status, expected_resource_version) do
    Agent.get_and_update(conn, fn state ->
      key = {gvk, namespace, name}

      case Map.fetch(state.objects, key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, current} ->
          if fetch_resource_version(current) != expected_resource_version do
            {{:error, :conflict}, state}
          else
            next_rv = state.rv + 1

            stored =
              current
              |> Map.put("status", status)
              |> put_resource_version(next_rv)

            new_state = %{
              state
              | objects: Map.put(state.objects, key, stored),
                rv: next_rv,
                compacted_before: advance_compaction(state.compacted_before, next_rv)
            }

            {{:ok, stored}, new_state}
          end
      end
    end)
  end

  @impl true
  def delete(conn, gvk, namespace, name) do
    Agent.update(conn, fn state ->
      %{state | objects: Map.delete(state.objects, {gvk, namespace, name})}
    end)

    :ok
  end

  @impl true
  def watch(conn, _gvk, _namespace, from_resource_version, _callback) do
    Agent.get(conn, fn state ->
      from_rv = parse_rv(from_resource_version)

      if (is_integer(from_rv) and state.compacted_before) && from_rv < state.compacted_before do
        {:error, :gone}
      else
        {:ok, make_ref()}
      end
    end)
  end

  defp fetch_name(object), do: get_in(object, ["metadata", "name"])
  defp fetch_resource_version(object), do: get_in(object, ["metadata", "resourceVersion"])

  defp put_resource_version(object, rv) do
    metadata =
      object
      |> Map.get("metadata", %{})
      |> Map.put("resourceVersion", Integer.to_string(rv))

    Map.put(object, "metadata", metadata)
  end

  # Keeps only the most recent `@retained_revisions` writes live. Once the
  # write counter has advanced far enough, this raises the compaction
  # boundary so older revisions age out on their own — no explicit
  # `compact_before/2` call required.
  defp advance_compaction(current, rv) when rv > @retained_revisions do
    candidate = rv - @retained_revisions + 1
    if current, do: max(current, candidate), else: candidate
  end

  defp advance_compaction(current, _rv), do: current

  defp parse_rv(rv) when is_binary(rv) do
    case Integer.parse(rv) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_rv(_), do: nil
end
