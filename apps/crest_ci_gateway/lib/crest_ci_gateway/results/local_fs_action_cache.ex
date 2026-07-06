defmodule CrestCiGateway.Results.LocalFsActionCache.SingleFlight do
  @moduledoc """
  Generic in-process fetch-once coordination.

  `run/3` executes a zero-arity function for a given `key` **at most once**
  among any number of concurrent callers using the same `key` on the same
  coordinator: the first caller to claim `key` becomes the leader and runs
  the function; every other concurrent caller for that `key` becomes a
  follower and blocks until the leader finishes, then receives the exact
  same result without ever invoking the function itself.

  This is a pure in-process concurrency primitive layered over operations
  that are already idempotent (e.g. a content-addressed filesystem write)
  — it holds no authoritative state of its own. If the coordinator process
  or the leader crashes mid-fetch, every waiter for that key is unblocked
  with `{:error, {:singleflight_leader_down, reason}}` rather than hanging
  forever; callers are expected to retry, which is safe precisely because
  the wrapped operation is idempotent and re-derivable from disk. Nothing
  here needs to survive a restart because nothing here is truth.

  Callers inject a started `t()` (a `GenServer.server()`) rather than this
  module starting its own coordinator — the process's lifecycle (started,
  supervised, named) is the caller's concern, not this module's.
  """

  use GenServer

  @typedoc "A running SingleFlight coordinator (pid or registered name)."
  @type t :: GenServer.server()

  @doc "Start a SingleFlight coordinator. Accepts standard GenServer options (e.g. `:name`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Run `fun` for `key` on `server`, at most once among concurrent callers.

  The first concurrent caller for `key` runs `fun.()` and returns its
  result. Every other concurrent caller for the same `key` blocks until
  that call completes and receives the identical result, never invoking
  `fun` itself.
  """
  @spec run(t(), term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(server, key, fun) when is_function(fun, 0) do
    case GenServer.call(server, {:claim, key}, :infinity) do
      :leader ->
        result = run_and_capture(fun)
        GenServer.cast(server, {:done, key, result})
        result

      {:follower, ref} ->
        receive do
          {:singleflight_result, ^ref, result} -> result
        end
    end
  end

  @doc """
  Return the number of callers currently blocked as followers on `key`.

  Not part of the core coordination protocol — exposed for testing and
  observability, so callers (and tests) can deterministically wait for a
  known number of followers to have joined an in-flight claim instead of
  guessing at timing.
  """
  @spec waiting_count(t(), term()) :: non_neg_integer()
  def waiting_count(server, key) do
    GenServer.call(server, {:waiting_count, key})
  end

  defp run_and_capture(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # -- GenServer ---------------------------------------------------------

  @impl GenServer
  def init(:ok) do
    {:ok, %{by_key: %{}, by_monitor: %{}}}
  end

  @impl GenServer
  def handle_call(
        {:claim, key},
        {from_pid, _tag},
        %{by_key: by_key, by_monitor: by_monitor} = state
      ) do
    case Map.fetch(by_key, key) do
      :error ->
        monitor_ref = Process.monitor(from_pid)
        by_key = Map.put(by_key, key, {monitor_ref, []})
        by_monitor = Map.put(by_monitor, monitor_ref, key)
        {:reply, :leader, %{state | by_key: by_key, by_monitor: by_monitor}}

      {:ok, {monitor_ref, waiters}} ->
        waiter_ref = make_ref()
        by_key = Map.put(by_key, key, {monitor_ref, [{from_pid, waiter_ref} | waiters]})
        {:reply, {:follower, waiter_ref}, %{state | by_key: by_key}}
    end
  end

  @impl GenServer
  def handle_call({:waiting_count, key}, _from, %{by_key: by_key} = state) do
    count =
      case Map.fetch(by_key, key) do
        {:ok, {_monitor_ref, waiters}} -> length(waiters)
        :error -> 0
      end

    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:done, key, result}, %{by_key: by_key, by_monitor: by_monitor} = state) do
    case Map.pop(by_key, key) do
      {{monitor_ref, waiters}, by_key} ->
        Process.demonitor(monitor_ref, [:flush])
        notify(waiters, result)
        {:noreply, %{state | by_key: by_key, by_monitor: Map.delete(by_monitor, monitor_ref)}}

      {nil, by_key} ->
        {:noreply, %{state | by_key: by_key}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %{by_monitor: by_monitor} = state) do
    case Map.pop(by_monitor, monitor_ref) do
      {nil, by_monitor} ->
        {:noreply, %{state | by_monitor: by_monitor}}

      {key, by_monitor} ->
        {{^monitor_ref, waiters}, by_key} = Map.pop(state.by_key, key)
        notify(waiters, {:error, {:singleflight_leader_down, reason}})
        {:noreply, %{state | by_key: by_key, by_monitor: by_monitor}}
    end
  end

  defp notify(waiters, result) do
    Enum.each(waiters, fn {pid, ref} -> send(pid, {:singleflight_result, ref, result}) end)
  end
end

defmodule CrestCiGateway.Results.LocalFsActionCache do
  @moduledoc """
  Filesystem adapter implementing `port.Results.ActionProxy` over
  content-addressed tarball paths.

  Layout: `<root>/actions/<repo-slug>/<resolved-ref>.tgz` — the path is
  fully derived from `(repo, ref)` alone, so an already-cached pair is
  resolved with a pure filesystem check and never touches the injected
  `fetcher`. Nothing about a resolve's outcome depends on in-process
  state: after a crash, the next resolve for a given `(repo, ref)` sees
  exactly the same filesystem truth any other replica or restart would.

  Concurrent first resolves of the same `(repo, ref)` are single-flighted
  through an injected `CrestCiGateway.Results.LocalFsActionCache.SingleFlight`
  coordinator: exactly one caller invokes `fetcher` for that key, ever;
  every other concurrent caller (and everyone after it completes) observes
  the same result without invoking `fetcher` again. The coordinator and the
  fetcher are both injected dependencies (Dependency Inversion) — this
  module creates neither; a fixture-backed fetcher and an isolated cache
  root make this easy to test without a real network fetch, and a future
  `codeload.github.com` fetcher slots in without any caller change
  (Open/Closed).
  """

  @behaviour CrestCiGateway.Results.ActionProxy

  alias CrestCiGateway.Results.LocalFsActionCache.SingleFlight

  @enforce_keys [:root, :fetcher, :singleflight]
  defstruct [:root, :fetcher, :singleflight]

  @typedoc """
  Fetches `(repo, ref)` into `dest_path`, creating no parent directories
  itself (the adapter ensures the destination directory exists before
  calling this). Returns `:ok` on success, `{:error, term()}` otherwise.
  """
  @type fetcher :: (repo :: String.t(), ref :: String.t(), dest_path :: String.t() ->
                      :ok | {:error, term()})

  @type t :: %__MODULE__{
          root: String.t(),
          fetcher: fetcher(),
          singleflight: SingleFlight.t()
        }

  @default_root "var"

  @doc """
  Build a cache adapter over `fetcher`, single-flighting concurrent misses
  through `singleflight`, rooted at `root` (defaults to `"var"`, giving
  paths like `var/actions/<repo-slug>/<ref>.tgz`).

  `fetcher` and `singleflight` are required, injected dependencies: pass a
  fixture-backed fetcher and a per-test `SingleFlight` coordinator in
  tests, a real fetch strategy and a supervised coordinator in production.
  """
  @spec new(fetcher(), SingleFlight.t(), String.t()) :: t()
  def new(fetcher, singleflight, root \\ @default_root)
      when is_function(fetcher, 3) and is_binary(root) do
    %__MODULE__{root: root, fetcher: fetcher, singleflight: singleflight}
  end

  @impl CrestCiGateway.Results.ActionProxy
  @spec resolve(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%__MODULE__{root: root, fetcher: fetcher, singleflight: singleflight}, repo, ref)
      when is_binary(repo) and is_binary(ref) do
    path = tarball_path(root, repo, ref)

    if File.regular?(path) do
      {:ok, path}
    else
      SingleFlight.run(singleflight, {root, repo, ref}, fn -> fetch(path, repo, ref, fetcher) end)
    end
  end

  # -- internal ------------------------------------------------------------

  defp fetch(path, repo, ref, fetcher) do
    # Re-check after winning the single-flight claim: a prior resolve may
    # have already cached this exact key on disk before this call even
    # started racing for the claim (e.g. it happened just before, or the
    # coordinator was restarted between an earlier winner and now). Never
    # re-fetch something that is already there.
    if File.regular?(path) do
      {:ok, path}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- fetcher.(repo, ref, path) do
        {:ok, path}
      end
    end
  end

  defp tarball_path(root, repo, ref) do
    Path.join([root, "actions", slug(repo), ref <> ".tgz"])
  end

  defp slug(repo), do: String.replace(repo, "/", "-")
end
