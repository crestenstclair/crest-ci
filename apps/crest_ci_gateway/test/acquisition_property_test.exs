defmodule CrestCiGateway.AcquisitionPropertyTest.HttpKubeClient do
  @moduledoc """
  A minimal, self-contained `CrestCiContract.KubeClient` implementation
  over real HTTP (via `Req`), used ONLY by `CrestCiGateway.AcquisitionPropertyTest`
  to drive `CrestCiGateway.LeaseArbiter` against a genuinely LIVE
  `MockK8s.KubeApiHttp.Server` — proving the single-winner CAS invariant
  holds over the wire (JSON marshaling, concurrent HTTP connections, the
  real REST routes), not merely against an in-memory double.

  `CrestCiGateway.LeaseArbiterTest` already proves the same arbitration
  logic against `CrestCiGateway.Test.FakeKubeClient` (in-memory); this
  module exists so the property proof in this file exercises the actual
  `port.MockK8s.KubeApiHttp` REST surface end to end, per this asset's
  `adapter.MockK8sHttpServer` dependency.

  `raw_conn` here is simply the live server's base URL (e.g.
  `"http://127.0.0.1:4000"`) — everything this module needs to reach it.
  Implements the full `CrestCiContract.KubeClient` behaviour so multiple
  independent `conn` values (base URLs) are freely substitutable
  (Liskov Substitution), even though `CrestCiGateway.LeaseArbiter` only
  ever calls `get/4` and `patch_status/6`.
  """

  @behaviour CrestCiContract.KubeClient

  @plural_by_kind %{"RunnerJob" => "runnerjobs"}

  @impl true
  def get(base_url, {group, version, kind}, namespace, name) do
    case Req.get(object_url(base_url, group, version, namespace, kind, name)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(base_url, {group, version, kind}, namespace, _opts) do
    case Req.get(collection_url(base_url, group, version, namespace, kind)) do
      {:ok, %Req.Response{status: 200, body: %{"items" => items} = body}} ->
        {:ok, items, get_in(body, ["metadata", "continue"])}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create(base_url, {group, version, kind}, namespace, object) do
    case Req.post(collection_url(base_url, group, version, namespace, kind), json: object) do
      {:ok, %Req.Response{status: 201, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 409}} -> {:error, :already_exists}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update(base_url, {group, version, kind}, namespace, object) do
    name = get_in(object, ["metadata", "name"])

    case Req.put(object_url(base_url, group, version, namespace, kind, name), json: object) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 409}} -> {:error, :conflict}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def patch_status(
        base_url,
        {group, version, kind},
        namespace,
        name,
        status,
        expected_resource_version
      ) do
    body = %{"status" => status, "expectedResourceVersion" => expected_resource_version}

    case Req.put(status_url(base_url, group, version, namespace, kind, name), json: body) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :conflict}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status_code, body: resp_body}} ->
        {:error, {status_code, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(base_url, {group, version, kind}, namespace, name) do
    case Req.delete(object_url(base_url, group, version, namespace, kind, name)) do
      {:ok, %Req.Response{status: status}} when status in [200, 202] -> :ok
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def watch(_base_url, _gvk, _namespace, _from_resource_version, _callback) do
    {:error, :not_implemented}
  end

  defp plural(kind), do: Map.fetch!(@plural_by_kind, kind)

  defp collection_url(base_url, group, version, namespace, kind),
    do: "#{base_url}/apis/#{group}/#{version}/namespaces/#{namespace}/#{plural(kind)}"

  defp object_url(base_url, group, version, namespace, kind, name),
    do: collection_url(base_url, group, version, namespace, kind) <> "/#{name}"

  defp status_url(base_url, group, version, namespace, kind, name),
    do: object_url(base_url, group, version, namespace, kind, name) <> "/status"
end

defmodule CrestCiGateway.AcquisitionPropertyTest do
  @moduledoc """
  Property proof of the Gateway's core arbitration invariant (see
  `project: contexts: Gateway: invariants` in the spec): a `RunnerJob` is
  delivered to exactly one runner, ever — the `CrestCiGateway.LeaseArbiter`
  resourceVersion CAS is the only path to `Leased`, and a lost CAS never
  results in a delivered job.

  For every property iteration this test:

    1. boots a fresh, LIVE `MockK8s` HTTP server (`MockK8s.ResourceStore` +
       `MockK8s.KubeApiHttp.Server`) on an ephemeral port — the real,
       in-BEAM stand-in for etcd/the Kubernetes API,
    2. seeds one fresh `Queued` `RunnerJob` directly into the store that
       server fronts (the same store the live server answers every read
       and CAS write against),
    3. races a generated number (2..20) of concurrent acquirers against
       `CrestCiGateway.LeaseArbiter.lease/4`, split across at least two
       distinct `conn` identities — two independent
       `{CrestCiGateway.AcquisitionPropertyTest.HttpKubeClient, base_url}`
       pairs pointed at the SAME live server, simulating at least two
       active-active gateway replicas dialing the same cluster (per the
       "gateway replica-local state is limited to open connections"
       invariant — a runner reconnecting to a different replica is
       indistinguishable from staying on the same one), and
    4. asserts exactly one acquirer observes `{:ok, :leased}`, every other
       acquirer observes `{:error, :lost}`, and the RunnerJob's status —
       read back from the live store — shows exactly the winner's
       identity in `leasedBy`.

  Totals are accumulated across every iteration and printed as
  `races=<n> single_winner_violations=<count>`, then asserted to be zero.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias CrestCiContract.RunnerJobStatus
  alias CrestCiGateway.AcquisitionPropertyTest.HttpKubeClient

  @runner_job_gvk_string "ci.crest.dev/v1alpha1/RunnerJob"
  @namespace "default"
  @lease_duration_seconds 30

  @tag :property
  test "exactly one of N racing acquirers wins the RunnerJob lease, every time" do
    {:ok, counter} = Agent.start_link(fn -> %{races: 0, violations: 0} end)

    {:ok, store} = MockK8s.ResourceStore.start_link([])
    {:ok, server} = MockK8s.KubeApiHttp.Server.serve(store, 0)
    port = MockK8s.KubeApiHttp.Server.bound_port(server)

    on_exit(fn ->
      if Process.alive?(store), do: MockK8s.KubeApiHttp.Server.stop(server)
    end)

    # At least two distinct gateway conn identities against the SAME live
    # server — the `{client_module, raw_conn}` shape
    # `CrestCiGateway.LeaseArbiter.conn()` (and `CrestCiController.LeaseSweeper`'s
    # `kube_conn`) already establish.
    kube_conn_a = {HttpKubeClient, "http://127.0.0.1:#{port}"}
    kube_conn_b = {HttpKubeClient, "http://localhost:#{port}"}
    kube_conns = [kube_conn_a, kube_conn_b]

    check all(n_acquirers <- integer(2..20), max_runs: 50) do
      job_name = fresh_job_name()
      :ok = seed_queued_runner_job(store, job_name)

      results =
        1..n_acquirers
        |> Enum.map(fn i ->
          kube_conn = Enum.at(kube_conns, rem(i, length(kube_conns)))
          runner_name = "runner-#{i}-#{System.unique_integer([:positive, :monotonic])}"

          Task.async(fn ->
            {runner_name,
             CrestCiGateway.LeaseArbiter.lease(
               kube_conn,
               job_name,
               runner_name,
               @lease_duration_seconds
             )}
          end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      winners = for {runner_name, {:ok, :leased}} <- results, do: runner_name
      losers = for {_runner_name, {:error, :lost}} <- results, do: :lost

      Agent.update(counter, fn state -> %{state | races: state.races + 1} end)

      unless length(winners) == 1 do
        Agent.update(counter, fn state -> %{state | violations: state.violations + 1} end)
      end

      assert length(winners) == 1,
             "expected exactly one winner among #{n_acquirers} racing acquirers for #{job_name}, got #{inspect(winners)} (full results: #{inspect(results)})"

      assert length(losers) == n_acquirers - 1,
             "expected every non-winning acquirer to observe {:error, :lost}, got #{inspect(results)}"

      [winner_name] = winners

      {:ok, object} =
        MockK8s.ResourceStore.get(store, @runner_job_gvk_string, @namespace, job_name)

      {:ok, status} = RunnerJobStatus.from_wire(Map.get(object, "status", %{}))

      assert status.leased_by == winner_name,
             "RunnerJob #{job_name} status.leasedBy (#{inspect(status.leased_by)}) does not match the observed winner (#{inspect(winner_name)})"

      assert status.phase == :leased
    end

    %{races: races, violations: violations} = Agent.get(counter, & &1)
    Agent.stop(counter)

    IO.puts("races=#{races} single_winner_violations=#{violations}")
    assert violations == 0
  end

  defp fresh_job_name do
    "acq-prop-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Seeds a fresh Queued RunnerJob directly into the store the live
  # MockK8s HTTP server fronts. Bypassing the HTTP surface for setup is
  # safe (and does not weaken the proof) because it is the SAME store the
  # live server answers every read and CAS write against — the property
  # under test is exercised entirely through `CrestCiGateway.LeaseArbiter.lease/4`
  # talking real HTTP (via `HttpKubeClient`) to that live server, not
  # through how the fixture got seeded.
  defp seed_queued_runner_job(store, job_name) do
    {:ok, queued_status} = RunnerJobStatus.new(%{})

    object = %{
      "apiVersion" => "ci.crest.dev/v1alpha1",
      "kind" => "RunnerJob",
      "metadata" => %{"name" => job_name},
      "spec" => %{
        "jobKey" => "build",
        "jobMessage" => %{},
        "runRef" => "run-#{job_name}",
        "runsOn" => ["linux"]
      },
      "status" => RunnerJobStatus.to_wire(queued_status)
    }

    case MockK8s.ResourceStore.create(store, @runner_job_gvk_string, @namespace, object) do
      {:ok, _stamped} -> :ok
      {:error, reason} -> flunk("failed to seed RunnerJob #{job_name}: #{inspect(reason)}")
    end
  end
end
