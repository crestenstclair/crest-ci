defmodule SimRunner.Demo.LocalCacheStore do
  @moduledoc """
  Minimal filesystem-backed cache store for the results E2E demo:
  `restore/2` looks up a committed blob by exact key (a soft `:miss`,
  never an error, when nothing is saved yet); `save/3` commits a blob
  under a key. Deliberately simpler than the real GitHub-compatible
  restore-key/scope semantics of `port.Results.CacheStore`
  (`CrestCiGateway.Results.CacheStore`) — this demo only needs "miss on
  run 1, hit on run 2 under the same key", so exact-key lookup is
  sufficient.

  Filesystem-backed, not ETS/Agent-backed: the cache must outlive each
  run's ephemeral controller/gateway boot
  (`SimRunner.Demo.ResultsOrchestrator` boots a fresh stack per run) so
  the SAME cache root is passed to both runs and this store's on-disk
  state is what actually carries the hit from run 2 back to run 1's
  save — never in-process memory that a fresh boot would lose. This
  mirrors the project-wide rule that no ETS/Agent state is ever the
  source of truth two components (here: two sequential runs) must
  agree on.

  This is deliberately a demo-scoped stand-in rather than a caller of
  `port.Results.CacheStore` (`CrestCiGateway.Results.CacheStore`, in
  `crest_ci_gateway`): `sim_runner` cannot declare a compile-time
  dependency on `crest_ci_gateway` at all (it already test-depends on
  `sim_runner`, which would create a cycle), and this demo's
  miss-then-hit scenario has no reason to couple itself to that
  context's GitHub-compatible restore-key/scope semantics. This small
  adapter provides a real, working exact-key hit/miss directly, owned
  entirely by this demo.
  """

  @doc """
  Look up the committed blob for `key`, rooted at `root`. `:miss` (not
  an error) when nothing has been saved under `key` yet.
  """
  @spec restore(String.t(), String.t()) :: {:ok, binary()} | :miss
  def restore(root, key) when is_binary(root) and is_binary(key) do
    case File.read(cache_path(root, key)) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> :miss
    end
  end

  @doc "Commit `content` under `key`, rooted at `root`."
  @spec save(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def save(root, key, content) when is_binary(root) and is_binary(key) and is_binary(content) do
    path = cache_path(root, key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  defp cache_path(root, key) do
    Path.join([root, "cache", safe_key(key)])
  end

  # Cache keys are free-form strings in the real port; this demo's key
  # is a fixed literal, but hashing it into the path keeps this adapter
  # safe against any key containing path separators or other
  # filesystem-unsafe characters.
  defp safe_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end
end
