defmodule CrestCiGateway.LocalFsActionCache do
  @moduledoc """
  Filesystem adapter implementing `port.Results.ActionProxy` — content-addressed,
  fetch-once resolution of an Actions-compatible action's tarball.

  Layout: `<root>/actions/<repo-slug>/<resolved-ref>.tgz` — the path is fully
  derived from `(repo, ref)`, so the same pair always maps to the same file.

  Single-flight de-duplication: an internal `GenServer` serializes concurrent
  `resolve/3` calls for the same `(repo, ref)` key. The first caller for a key
  triggers the injected fetcher exactly once; every other concurrent caller
  for that key (and every caller after the fetch completes) is answered
  without invoking the fetcher again — either by joining the in-flight fetch
  as a waiter, or by a plain cache hit once the tarball exists on disk.

  This GenServer holds no authoritative state — it is a local, disposable
  coordination point, not a source of truth any other component depends on.
  The only durable fact is the tarball file itself: if the process crashes
  mid-fetch, the partially written file is never left at its final path
  (the fetcher writes to a private temp file first, then atomically renames
  it into place), so a restart simply re-observes "file absent" and
  refetches — the adapter converges the same way a freshly booted process
  would, with no risk of a caller ever reading a truncated tarball.

  The fetcher is injected (Dependency Inversion) as a 2-arity function
  `(repo, ref) -> {:ok, binary()} | {:error, term()}` returning the tarball's
  raw bytes. This slice injects a fixture-backed fetcher in tests; a future
  `codeload.github.com` fetcher slots in without any caller change
  (Open/Closed) — only `new/2`'s argument changes.
  """

  @behaviour CrestCiGateway.Results.ActionProxy

  use GenServer

  @enforce_keys [:root, :server]
  defstruct [:root, :server]

  @typedoc "Fetches raw tarball bytes for `(repo, ref)`; called at most once, ever, per key."
  @type fetcher :: (String.t(), String.t() -> {:ok, binary()} | {:error, term()})

  @type t :: %__MODULE__{root: String.t(), server: GenServer.server()}

  @default_root "var/actions"

  @doc """
  Build a cache rooted at `root` (defaults to `"var/actions"`), backed by
  `fetcher` for cache misses. Starts (and owns) the single-flight
  coordination process; pass a distinct `root` per test to isolate
  filesystem footprint.
  """
  @spec new(fetcher(), String.t()) :: t()
  def new(fetcher, root \\ @default_root) when is_function(fetcher, 2) and is_binary(root) do
    {:ok, server} = GenServer.start_link(__MODULE__, %{root: root, fetcher: fetcher})
    %__MODULE__{root: root, server: server}
  end

  @impl CrestCiGateway.Results.ActionProxy
  @spec resolve(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%__MODULE__{server: server}, repo, ref)
      when is_binary(repo) and is_binary(ref) do
    GenServer.call(server, {:resolve, repo, ref}, :infinity)
  end

  @doc "Deterministic content-addressed path for `(repo, ref)` under `root`."
  @spec tarball_path(String.t(), String.t(), String.t()) :: String.t()
  def tarball_path(root, repo, ref) do
    Path.join([root, "actions", slug(repo), ref <> ".tgz"])
  end

  defp slug(repo), do: String.replace(repo, "/", "-")

  # -- GenServer: single-flight coordination ----------------------------

  @impl GenServer
  def init(%{root: root, fetcher: fetcher}) do
    {:ok, %{root: root, fetcher: fetcher, inflight: %{}}}
  end

  @impl GenServer
  def handle_call({:resolve, repo, ref}, from, state) do
    key = {repo, ref}
    path = tarball_path(state.root, repo, ref)

    cond do
      File.regular?(path) ->
        {:reply, {:ok, path}, state}

      Map.has_key?(state.inflight, key) ->
        {:noreply, update_in(state.inflight[key], &[from | &1])}

      true ->
        owner = self()
        fetcher = state.fetcher

        spawn_link(fn -> run_fetch(owner, key, path, fetcher) end)

        {:noreply, put_in(state.inflight[key], [from])}
    end
  end

  @impl GenServer
  def handle_info({:fetch_result, key, result}, state) do
    {waiters, inflight} = Map.pop(state.inflight, key, [])

    Enum.each(waiters, fn from -> GenServer.reply(from, result) end)

    {:noreply, %{state | inflight: inflight}}
  end

  defp run_fetch(owner, {repo, ref} = key, path, fetcher) do
    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, bytes} <- fetcher.(repo, ref),
           :ok <- write_atomic(path, bytes) do
        {:ok, path}
      end

    send(owner, {:fetch_result, key, result})
  end

  defp write_atomic(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, bytes) do
      File.rename(tmp, path)
    end
  end
end
