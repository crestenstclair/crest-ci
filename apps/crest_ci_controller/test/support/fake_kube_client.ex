defmodule CrestCiController.Test.FakeKubeClient do
  @moduledoc """
  Minimal in-memory `CrestCiContract.KubeClient` reference adapter used
  only by this app's own test suite, so `LeaderElector` tests do not
  depend on any other resource's adapter (e.g. the real mock-k8s HTTP
  server) having been generated yet.

  Backed by an `Agent` standing in for "the cluster" for a single test —
  this is disposable test fixture code, not a production component, so it
  does not fall under the project invariant against ETS/Agent-as-source-
  of-truth for controller/gateway coordination state.

  `conn` for this adapter is the Agent pid returned by `start_link/0`.
  """

  @behaviour CrestCiContract.KubeClient

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
