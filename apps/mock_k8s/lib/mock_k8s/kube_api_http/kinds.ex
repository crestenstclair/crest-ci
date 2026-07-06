defmodule MockK8s.KubeApiHttp.Kinds do
  @moduledoc """
  Registry of the group/version/kind/plural mappings the mock API server
  understands, translating between REST path segments (group, version,
  plural) and the `gvk` string key `MockK8s.ResourceStore` uses internally.

  This is the one place new registered kinds get added — the router and the
  watch bridge both go through this module rather than hard-coding the
  mapping themselves.

  Registered kinds: `WorkflowDefinition`, `WorkflowRun`, `RunnerJob`,
  `RunnerPool` (`ci.crest.dev/v1alpha1`); `Lease` (`coordination.k8s.io/v1`);
  `Pod`, `Secret`, `ConfigMap` (`core/v1`).
  """

  @type registration :: %{
          group: String.t(),
          version: String.t(),
          kind: String.t(),
          plural: String.t()
        }

  @registered [
    %{
      group: "ci.crest.dev",
      version: "v1alpha1",
      kind: "WorkflowDefinition",
      plural: "workflowdefinitions"
    },
    %{group: "ci.crest.dev", version: "v1alpha1", kind: "WorkflowRun", plural: "workflowruns"},
    %{group: "ci.crest.dev", version: "v1alpha1", kind: "RunnerJob", plural: "runnerjobs"},
    %{group: "ci.crest.dev", version: "v1alpha1", kind: "RunnerPool", plural: "runnerpools"},
    %{group: "coordination.k8s.io", version: "v1", kind: "Lease", plural: "leases"},
    %{group: "core", version: "v1", kind: "Pod", plural: "pods"},
    %{group: "core", version: "v1", kind: "Secret", plural: "secrets"},
    %{group: "core", version: "v1", kind: "ConfigMap", plural: "configmaps"}
  ]

  @doc "Look up a registration by its REST path segments."
  @spec lookup(String.t(), String.t(), String.t()) :: {:ok, registration()} | {:error, :not_found}
  def lookup(group, version, plural) do
    case Enum.find(
           @registered,
           &(&1.group == group and &1.version == version and &1.plural == plural)
         ) do
      nil -> {:error, :not_found}
      reg -> {:ok, reg}
    end
  end

  @doc "The `MockK8s.ResourceStore` gvk key for a registration: `\"group/version/kind\"`."
  @spec gvk(registration()) :: String.t()
  def gvk(%{group: group, version: version, kind: kind}), do: "#{group}/#{version}/#{kind}"

  @doc "The Kubernetes `apiVersion` string for a registration (bare version for the core group)."
  @spec api_version(registration()) :: String.t()
  def api_version(%{group: "core", version: version}), do: version
  def api_version(%{group: group, version: version}), do: "#{group}/#{version}"

  @doc """
  Reconstruct the internal gvk key from an already-stamped object's
  `apiVersion` + `kind` fields.

  Every object created or updated through `MockK8s.KubeApiHttp.Router`
  carries both fields (stamped from the registration the request resolved
  to). This is used by `MockK8s.KubeApiHttp.Bridge`, which only has the raw
  `MockK8s.ResourceStore` write event — not the original request's path
  segments — to work from.
  """
  @spec gvk_from_object(map()) :: {:ok, String.t()} | {:error, :invalid_object}
  def gvk_from_object(%{"apiVersion" => api_version, "kind" => kind})
      when is_binary(api_version) and is_binary(kind) do
    case String.split(api_version, "/", parts: 2) do
      [version] -> {:ok, "core/#{version}/#{kind}"}
      [group, version] -> {:ok, "#{group}/#{version}/#{kind}"}
    end
  end

  def gvk_from_object(_object), do: {:error, :invalid_object}
end
