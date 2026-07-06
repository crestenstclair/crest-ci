defmodule CrestCiGateway.Test.FakeKubeClient do
  @moduledoc """
  Test-only reference adapter for `CrestCiContract.KubeClient`, scoped to
  `crest_ci_gateway`'s own test suite (mirrors
  `CrestCiContract.Test.FakeKubeClient`, which is private to the
  `crest_ci_contract` app's tests and not compiled/exported for other
  umbrella apps to reuse).

  Backs the port with an `Agent` so `lease_arbiter_test.exs` can exercise
  the resourceVersion compare-and-swap arbitration contract end-to-end
  without a real (or mock-HTTP) Kubernetes API server. This is test
  fixture code, not a production component — the project invariant
  against ETS/Agent-as-source-of-truth applies to controller/gateway
  coordination state, not to a disposable per-test double standing in for
  "the cluster".

  `conn` for this adapter is the Agent pid returned by `start_link/0`.
  """

  @behaviour CrestCiContract.KubeClient

  @doc "Start a fresh, empty fake store. The returned pid is the `conn` for every callback."
  @spec start_link() :: {:ok, pid()}
  def start_link do
    Agent.start_link(fn -> %{objects: %{}, rv: 0} end)
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
        new_state = %{state | objects: Map.put(state.objects, key, stored), rv: next_rv}
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
            new_state = %{state | objects: Map.put(state.objects, key, stored), rv: next_rv}
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

            new_state = %{state | objects: Map.put(state.objects, key, stored), rv: next_rv}
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
  def watch(_conn, _gvk, _namespace, _from_resource_version, _callback) do
    {:ok, make_ref()}
  end

  @doc """
  Test-only helper: simulates another writer (the controller, or another
  active-active gateway replica) advancing an already-stored object's
  resourceVersion behind the caller's back, so a subsequent `update/4` or
  `patch_status/6` against the caller's now-stale copy observes
  `{:error, :conflict}` — used by `StatusProjectorTest` to exercise the
  reread-and-retry path without a second real writer.
  """
  @spec external_write(pid(), CrestCiContract.KubeClient.gvk(), String.t(), String.t()) :: :ok
  def external_write(conn, gvk, namespace, name) do
    Agent.update(conn, fn state ->
      key = {gvk, namespace, name}

      case Map.fetch(state.objects, key) do
        {:ok, current} ->
          next_rv = state.rv + 1
          stored = put_resource_version(current, next_rv)
          %{state | objects: Map.put(state.objects, key, stored), rv: next_rv}

        :error ->
          state
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
end
