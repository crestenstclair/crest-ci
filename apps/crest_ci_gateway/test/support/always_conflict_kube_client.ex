defmodule CrestCiGateway.Test.AlwaysConflictKubeClient do
  @moduledoc """
  Test-only `CrestCiContract.KubeClient` wrapper that delegates reads to a
  real `CrestCiGateway.Test.FakeKubeClient` but always reports
  `{:error, :conflict}` on `patch_status/6`, counting attempts — used to
  prove `StatusProjector` bounds its reread-and-retry loop instead of
  spinning forever, and never forces a write through on exhaustion.
  """

  @behaviour CrestCiContract.KubeClient

  alias CrestCiGateway.Test.FakeKubeClient

  @impl true
  def get({pid, _counter}, gvk, namespace, name),
    do: FakeKubeClient.get(pid, gvk, namespace, name)

  @impl true
  def list({pid, _counter}, gvk, namespace, opts),
    do: FakeKubeClient.list(pid, gvk, namespace, opts)

  @impl true
  def create({pid, _counter}, gvk, namespace, object),
    do: FakeKubeClient.create(pid, gvk, namespace, object)

  @impl true
  def update({pid, _counter}, gvk, namespace, object),
    do: FakeKubeClient.update(pid, gvk, namespace, object)

  @impl true
  def patch_status({_pid, counter}, _gvk, _namespace, _name, _status, _expected_resource_version) do
    Agent.update(counter, &(&1 + 1))
    {:error, :conflict}
  end

  @impl true
  def delete({pid, _counter}, gvk, namespace, name),
    do: FakeKubeClient.delete(pid, gvk, namespace, name)

  @impl true
  def watch({pid, _counter}, gvk, namespace, from_resource_version, callback),
    do: FakeKubeClient.watch(pid, gvk, namespace, from_resource_version, callback)
end
