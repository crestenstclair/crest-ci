defmodule CrestCiController.Cluster.RealPodOrchestrator do
  @moduledoc """
  The scale-per-job orchestration against a REAL Kubernetes cluster: on a
  `Queued` `RunnerJob`, render its `RunnerPodSpec` via
  `CrestCiController.Cluster.PodSpecBuilder` and create the real `Pod`
  object via `CrestCiContract.ReqKubeClient`, tolerating `{:error,
  :already_exists}` as success.

  This mirrors the in-BEAM `CrestCiController.RunReconciler`'s own
  `{:create_pod, _}` command handling exactly — deterministic pod
  naming (the `RunnerJob`'s own name) is what makes a 409 on `create` a
  safe replay no-op there too — but is a narrower, standalone entry
  point dedicated to the real-cluster path (`mix crest_ci.demo_k3d`):
  where `RunReconciler` dispatches through an injected
  `{adapter_module, adapter_conn}` pair so it can run against the
  in-BEAM mock or a real cluster alike, this module is bound
  specifically to `CrestCiContract.ReqKubeClient` — "real" is this
  module's entire reason to exist, so there is no adapter seam left to
  invert here. `conn` is whatever
  `CrestCiController.Cluster.ClusterConnBuilder` built from a real
  kubeconfig (or, in tests, `ReqKubeClient.new/2` pointed at a
  `MockK8s` HTTP server — the same wire protocol either way).

  The rendered `Pod` wire object carries an `ownerReference` back to
  the `RunnerJob` (so Kubernetes garbage-collects the pod automatically
  once the `RunnerJob` is deleted) and `restartPolicy: "Never"` (the
  ephemeral, run-once contract `RunnerPodSpec` itself does not encode —
  see its own moduledoc). Building that wire object is this module's
  entire job; it holds no state of its own and performs no
  reconciliation loop — the caller decides when and how often to call
  `reconcile/4`.
  """

  alias CrestCiContract.ReqKubeClient
  alias CrestCiController.Cluster.{PodSpecBuilder, RunnerPodSpec}

  @pod_gvk {"core", "v1", "Pod"}
  @runner_job_api_version "ci.crest.dev/v1alpha1"
  @runner_job_kind "RunnerJob"

  @type builder_opts :: %{
          required(:image) => String.t(),
          required(:gateway_url) => String.t(),
          required(:service_account) => String.t(),
          required(:active_deadline_seconds) => pos_integer(),
          optional(:profile) => map(),
          optional(:demo) => boolean(),
          optional(:demo_headless) => boolean()
        }

  @doc """
  Reconciles one `RunnerJob` against a real (or MockK8s-backed)
  cluster: renders its `RunnerPodSpec` and creates the owning `Pod`.

  `conn` is a `CrestCiContract.ReqKubeClient` conn (see
  `CrestCiController.Cluster.ClusterConnBuilder`). `runner_job` is the
  decoded `RunnerJob` wire object. `namespace` is where the `Pod` is
  created. `builder_opts` supplies `PodSpecBuilder.build/1`'s remaining
  required fields (`:image`, `:gateway_url`, `:service_account`,
  `:active_deadline_seconds`) plus its optional resource-profile /
  demo-flag overrides.

  Returns `:ok` both when the `Pod` is freshly created and when it
  already existed (`{:error, :already_exists}` from a replayed
  reconcile against the same deterministically-named `RunnerJob` is
  absorbed as a no-op, never surfaced as a failure) — any other error
  is returned as `{:error, reason}`.
  """
  @spec reconcile(ReqKubeClient.conn(), map(), String.t(), builder_opts()) ::
          :ok | {:error, term()}
  def reconcile(conn, runner_job, namespace, builder_opts)
      when is_map(runner_job) and is_binary(namespace) and is_map(builder_opts) do
    fields =
      builder_opts
      |> Map.take([
        :image,
        :gateway_url,
        :service_account,
        :active_deadline_seconds,
        :profile,
        :cpu_request,
        :cpu_limit,
        :mem_request,
        :mem_limit,
        :demo,
        :demo_headless
      ])
      |> Map.merge(%{runner_job: runner_job, namespace: namespace})

    with {:ok, pod_spec} <- PodSpecBuilder.build(fields) do
      conn
      |> ReqKubeClient.create(@pod_gvk, namespace, pod_object(pod_spec, runner_job))
      |> tolerate_already_exists()
    end
  end

  defp tolerate_already_exists({:ok, _created}), do: :ok
  defp tolerate_already_exists({:error, :already_exists}), do: :ok
  defp tolerate_already_exists({:error, reason}), do: {:error, reason}

  defp pod_object(%RunnerPodSpec{} = pod_spec, runner_job) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => pod_spec.name,
        "namespace" => pod_spec.namespace,
        "labels" => pod_spec.labels,
        "ownerReferences" => [owner_reference(runner_job)]
      },
      "spec" =>
        pod_spec
        |> RunnerPodSpec.to_wire()
        |> Map.put("restartPolicy", "Never")
    }
  end

  defp owner_reference(runner_job) do
    %{
      "apiVersion" => Map.get(runner_job, "apiVersion", @runner_job_api_version),
      "kind" => @runner_job_kind,
      "name" => get_in(runner_job, ["metadata", "name"]),
      "uid" => get_in(runner_job, ["metadata", "uid"]) || get_in(runner_job, ["metadata", "name"])
    }
  end
end
