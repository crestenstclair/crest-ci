defmodule CrestCiGateway.JobDispatcher do
  @moduledoc """
  `applicationService.Gateway.JobDispatcher` — parks a runner's long-poll
  request for up to `deadline_ms`, and answers it with a `RunnerJob`'s
  rendered `job_message` the instant this call wins the
  `CrestCiGateway.LeaseArbiter` resourceVersion CAS for a `Queued`
  `RunnerJob` whose `runsOn` set equals the caller's `runs_on_labels`.

  ## Level-triggered, not edge-triggered

  Every wake-up this module ever acts on — the very first scan on entry
  ("poll arrival when jobs already wait"), a
  `port.Contract.KubeClient.watch/5` event, or the bounded periodic
  rescan below — takes exactly the same action: re-list every
  `RunnerJob` in scope, filter to `Queued` jobs whose `runsOn` set
  equals the caller's, and attempt `CrestCiGateway.LeaseArbiter.lease/4`
  on each candidate (in deterministic name order) until one wins or the
  candidates are exhausted. Nothing here trusts the *content* of a
  watch event to decide what to do next — only that *something changed*
  is reason enough to re-scan. Per the project's
  level-triggered/idempotent invariant, replaying any event sequence in
  any order, or replaying the same "something changed" signal any
  number of times, converges to the same outcome: either this call is
  now the lease's confirmed winner, or it keeps waiting.

  ## No shared mutable state

  This module keeps no state of its own beyond the stack of the calling
  process for the duration of one `poll/3` call. A parked long-poll is
  exactly the "open connection" the architectural invariants carve out
  as acceptable gateway-replica-local state: if the process (or the
  whole replica) is killed mid-poll, the runner simply reconnects (to
  any replica, indistinguishably) and re-polls — no authoritative fact
  about job assignment ever lived anywhere but the `RunnerJob` resource
  itself, arbitrated purely by `LeaseArbiter`'s resourceVersion CAS.

  ## Dependency inversion

  `poll/3` never calls `CrestCiContract.KubeClient` or
  `CrestCiGateway.LeaseArbiter` through a hard-coded module name: every
  collaborator arrives via the injected `#{inspect(__MODULE__)}.Deps`
  struct — a `{client_module, raw_conn}` `kube_conn` pair (mirroring
  every other `KubeClient` caller in this project) plus a `lease`
  function value. Any `KubeClient` adapter, and any `lease`-shaped
  function (the real `CrestCiGateway.LeaseArbiter.lease/4` or a test
  stub), is substitutable underneath this module with no change here
  (Liskov Substitution / Dependency Inversion).

  ## No busy-waiting, no `Process.sleep/1`

  Waiting is implemented entirely with `receive ... after` — a bounded
  deadline wait that either wakes early on a watch-delivered message or
  falls through to a rescan after `@rescan_interval_ms`. There is no
  `Process.sleep/1` anywhere on this path, matching the project's ban on
  sleep-based coordination in production code.
  """

  require Logger

  alias CrestCiContract.KubeClient
  alias CrestCiContract.RunnerJobSpec
  alias CrestCiContract.RunnerJobStatus

  @gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"

  # Bounds how long a single receive-after wait can go before this
  # process re-lists on its own, even when the injected KubeClient
  # adapter never delivers a watch event (every fake/test adapter in
  # this project's suites stubs watch/5 as a no-op that never invokes
  # its callback). This is a receive-with-timeout, never
  # `Process.sleep/1`, and it is what keeps "poll arrival when jobs
  # already wait" and "wakes up on a later change" the *same* code path
  # (re-list-and-attempt) rather than two.
  @rescan_interval_ms 50

  defmodule Deps do
    @moduledoc """
    Collaborators `JobDispatcher.poll/3` needs, supplied per-request by
    whichever assembler wires a gateway replica (and one authenticated
    runner) together. `leased_by` is that runner's identity — the value
    recorded as `RunnerJobStatus.leasedBy` on a won race — so unlike
    `kube_conn` and `lease` it typically varies per call rather than
    being the same injected value across every request a replica
    serves.

    `list_notifier`, when present, is invoked once per full list-scan
    this module performs (the initial scan and every rescan after a
    wake-up). It exists purely so tests can synchronize on "a scan just
    happened" via message-passing instead of sleeping; production
    callers simply omit it (defaults to `nil`, a no-op).
    """

    @enforce_keys [:kube_conn, :lease, :leased_by]
    defstruct kube_conn: nil,
              lease: nil,
              leased_by: nil,
              lease_duration_seconds: 30,
              list_notifier: nil

    @typedoc "Matches `CrestCiGateway.LeaseArbiter.lease/4`'s signature."
    @type lease_fun ::
            (term(), String.t(), String.t(), non_neg_integer() ->
               {:ok, :leased} | {:error, :lost | term()})

    @type t :: %__MODULE__{
            kube_conn: term(),
            lease: lease_fun(),
            leased_by: String.t(),
            lease_duration_seconds: non_neg_integer(),
            list_notifier: (-> any()) | nil
          }
  end

  @typedoc "The rendered protocol payload a runner executes — `RunnerJobSpec.job_message`."
  @type job_message :: map()

  @doc """
  Park this call for up to `deadline_ms` milliseconds waiting for a
  `Queued` `RunnerJob` whose `runsOn` set equals `runs_on_labels` that
  this call can win the lease race for.

  Returns `{:ok, job_message}` the instant `deps.lease` (backed by
  `CrestCiGateway.LeaseArbiter.lease/4`) wins the resourceVersion CAS
  for a matching candidate — `job_message` is that `RunnerJob`'s
  `CrestCiContract.RunnerJobSpec.job_message`, exactly as rendered by
  the controller. Returns `:timeout` once `deadline_ms` elapses with no
  win.

  `runs_on_labels` matches a `RunnerJob` by *set* equality against its
  `RunnerJobSpec.runs_on` — the same tag set the controller stamped on
  the job at creation.

  A lost CAS (`{:error, :lost}`) or any other lease failure on a
  candidate simply moves this call on to the next candidate (or the
  next scan) — per the project invariant, a lost race is never retried
  against the same job, and this call never forces or reinterprets
  another actor's write.
  """
  @spec poll(Deps.t(), [String.t()], non_neg_integer()) :: {:ok, job_message()} | :timeout
  def poll(%Deps{} = deps, runs_on_labels, deadline_ms)
      when is_list(runs_on_labels) and is_integer(deadline_ms) and deadline_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    wanted = MapSet.new(runs_on_labels)
    {client, raw_conn} = deps.kube_conn

    # Subscribing before the first scan means any event a real
    # watch-capable adapter delivers between "start" and "first scan
    # completes" is not lost — the next iteration's re-scan
    # (level-triggered) simply confirms nothing new if it raced us. A
    # no-op `watch/5` (every fake adapter in this project's tests today)
    # makes this a harmless subscription; the bounded periodic rescan
    # below is what actually drives progress in that case.
    case client.watch(raw_conn, @gvk, @namespace, "", watch_callback(self())) do
      {:ok, _watch_ref} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "JobDispatcher: watch subscribe failed, falling back to periodic rescan: #{inspect(reason)}"
        )
    end

    dispatch_loop(deps, client, raw_conn, wanted, deadline)
  end

  # -- internal --------------------------------------------------------

  @spec watch_callback(pid()) :: KubeClient.watch_callback()
  defp watch_callback(parent) do
    fn _event -> send(parent, {:crest_ci_job_dispatcher, :runner_job_event}) end
  end

  @spec dispatch_loop(Deps.t(), module(), term(), MapSet.t(), integer()) ::
          {:ok, job_message()} | :timeout
  defp dispatch_loop(deps, client, raw_conn, wanted, deadline) do
    case scan_and_attempt(deps, client, raw_conn, wanted) do
      {:ok, job_message} ->
        {:ok, job_message}

      :none ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          :timeout
        else
          wait_ms = min(remaining_ms, @rescan_interval_ms)

          receive do
            {:crest_ci_job_dispatcher, :runner_job_event} ->
              dispatch_loop(deps, client, raw_conn, wanted, deadline)
          after
            wait_ms -> dispatch_loop(deps, client, raw_conn, wanted, deadline)
          end
        end
    end
  end

  @spec scan_and_attempt(Deps.t(), module(), term(), MapSet.t()) ::
          {:ok, job_message()} | :none
  defp scan_and_attempt(deps, client, raw_conn, wanted) do
    notify(deps)

    client
    |> list_all(raw_conn, nil)
    |> Enum.filter(&matches?(&1, wanted))
    |> Enum.sort_by(&object_name/1)
    |> attempt_each(deps)
  end

  @spec notify(Deps.t()) :: :ok
  defp notify(%Deps{list_notifier: nil}), do: :ok

  defp notify(%Deps{list_notifier: fun}) when is_function(fun, 0) do
    fun.()
    :ok
  end

  @spec list_all(module(), term(), KubeClient.continue_token()) :: [KubeClient.object()]
  defp list_all(client, raw_conn, continue) do
    opts = if continue, do: [continue: continue], else: []

    case client.list(raw_conn, @gvk, @namespace, opts) do
      {:ok, objects, nil} -> objects
      {:ok, objects, next} -> objects ++ list_all(client, raw_conn, next)
      {:error, _reason} -> []
    end
  end

  @spec matches?(KubeClient.object(), MapSet.t()) :: boolean()
  defp matches?(object, wanted) do
    with {:ok, status} <- RunnerJobStatus.from_wire(Map.get(object, "status", %{})),
         true <- status.phase == :queued,
         {:ok, spec} <- RunnerJobSpec.from_wire(Map.get(object, "spec", %{})) do
      MapSet.new(spec.runs_on) == wanted
    else
      _ -> false
    end
  end

  @spec attempt_each([KubeClient.object()], Deps.t()) :: {:ok, job_message()} | :none
  defp attempt_each([], _deps), do: :none

  defp attempt_each([object | rest], deps) do
    name = object_name(object)

    case deps.lease.(deps.kube_conn, name, deps.leased_by, deps.lease_duration_seconds) do
      {:ok, :leased} ->
        {:ok, spec} = RunnerJobSpec.from_wire(Map.get(object, "spec", %{}))
        {:ok, spec.job_message}

      {:error, :lost} ->
        attempt_each(rest, deps)

      {:error, reason} ->
        Logger.warning("JobDispatcher: lease attempt failed for #{name}: #{inspect(reason)}")
        attempt_each(rest, deps)
    end
  end

  @spec object_name(KubeClient.object()) :: String.t()
  defp object_name(object), do: get_in(object, ["metadata", "name"])
end
