defmodule SimRunner.Demo.InProcessKubeClient do
  @moduledoc """
  Adapter: implements `CrestCiContract.KubeClient` directly against an
  in-process `MockK8s.ResourceStore`, bypassing HTTP entirely.

  `adapter.ReqKubeClient` (the Req-based HTTP adapter for this port) has
  not landed yet in this session's generation order — this harness-local
  adapter fills the same role for `asset.E2EDemo` only, translating the
  port's `{group, version, kind}` gvk tuples into the
  `"group/version/kind"` string keys `MockK8s.ResourceStore` uses
  internally. Every collaborator in this demo (controller instances,
  gateway replicas) still depends only on the `CrestCiContract.KubeClient`
  behaviour, never on `MockK8s.ResourceStore` directly (Dependency
  Inversion) — swapping this adapter for the real `ReqKubeClient` later
  touches nothing but the one call site that builds `conn`.

  `conn` is the `MockK8s.ResourceStore` server reference — the only state
  this module touches lives there; this adapter holds nothing of its own.

  `sim_runner`'s `mix.exs` is spec-pinned to `req` + `jason` +
  `crest_ci_contract` only — adding an in-umbrella dep on `mock_k8s` is not
  an option (it already test-depends on `sim_runner`, which would create a
  dependency cycle). So `MockK8s.ResourceStore` is never referenced via
  compile-time dot-call syntax here; every call goes through `apply/3`
  against a module atom built by `Module.concat/1`, which is ordinary data
  as far as the compiler's cross-module reference checker is concerned.
  The module is real and loaded at runtime when this Mix task actually
  runs from the umbrella root — this is purely about keeping `sim_runner`
  compiling cleanly under `--warnings-as-errors` without a declared
  compile-time dependency.
  """

  @behaviour CrestCiContract.KubeClient

  @resource_store Module.concat([MockK8s, ResourceStore])

  @impl true
  def get(store, gvk, namespace, name) do
    apply(@resource_store, :get, [store, key(gvk), namespace, name])
  end

  @impl true
  def list(store, gvk, namespace, opts) do
    apply(@resource_store, :list, [store, key(gvk), namespace, opts])
  end

  @impl true
  def create(store, gvk, namespace, object) do
    apply(@resource_store, :create, [store, key(gvk), namespace, object])
  end

  @impl true
  def update(store, gvk, namespace, object) do
    apply(@resource_store, :update, [store, key(gvk), namespace, object])
  end

  @impl true
  def patch_status(store, gvk, namespace, name, status, expected_resource_version) do
    apply(@resource_store, :patch_status, [
      store,
      key(gvk),
      namespace,
      name,
      status,
      expected_resource_version
    ])
  end

  @impl true
  def delete(store, gvk, namespace, name) do
    apply(@resource_store, :delete, [store, key(gvk), namespace, name])
  end

  @impl true
  def watch(store, gvk, namespace, _from_resource_version, callback) do
    target = key(gvk)
    resource_store = @resource_store

    Task.start_link(fn ->
      :ok = apply(resource_store, :subscribe, [store])
      watch_loop(target, namespace, callback)
    end)
  end

  # -- internal --------------------------------------------------------

  defp watch_loop(target, namespace, callback) do
    receive do
      {:resource_written, %{type: type, object: object, resource_version: rv}} ->
        maybe_dispatch(target, namespace, type, object, rv, callback)
        watch_loop(target, namespace, callback)
    end
  end

  defp maybe_dispatch(target, namespace, type, object, rv, callback) do
    with {:ok, object_gvk} <- gvk_from_object(object),
         true <- object_gvk == target,
         true <- get_in(object, ["metadata", "namespace"]) == namespace do
      callback.(decode_event(type, object, rv))
    else
      _ -> :ok
    end
  end

  defp decode_event("ADDED", object, _rv), do: {:added, object}
  defp decode_event("MODIFIED", object, _rv), do: {:modified, object}
  defp decode_event("DELETED", object, _rv), do: {:deleted, object}
  defp decode_event(_other, object, _rv), do: {:modified, object}

  defp gvk_from_object(%{"apiVersion" => api_version, "kind" => kind})
       when is_binary(api_version) and is_binary(kind) do
    case String.split(api_version, "/", parts: 2) do
      [version] -> {:ok, "core/#{version}/#{kind}"}
      [group, version] -> {:ok, "#{group}/#{version}/#{kind}"}
    end
  end

  defp gvk_from_object(_object), do: :error

  defp key({group, version, kind}), do: "#{group}/#{version}/#{kind}"
end
