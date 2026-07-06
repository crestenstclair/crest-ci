defmodule CrestCiGateway.Results.ActionProxy do
  @moduledoc """
  Port: fetch-once, content-addressed resolution of an Actions-compatible
  action's tarball.

  `port.Results.ActionProxy` — an abstraction over "how do we get the
  tarball for a given (repo, resolved ref)" so that runner-facing callers
  depend on this behaviour instead of a concrete fetch technology. This
  slice's adapter (`adapter.LocalFsActionCache`) resolves against a local
  fixture directory with an injected fetcher; a future `codeload.github.com`
  fetcher slots in without touching any caller (Open/Closed).

  Contract:

    * `resolve/3` is content-addressed by `(repo, ref)` — the same pair
      always maps to the same tarball path.
    * A given `(repo, ref)` is fetched **at most once, ever**. Concurrent
      first resolves of the same key single-flight into exactly one fetch;
      every other concurrent caller (and every caller after the first
      completes) observes a cache hit and never invokes the fetcher again.
    * Cache hits never invoke the fetcher — only the single winning fetch
      for a key does.

  `proxy` is an opaque struct identifying both the implementing module (via
  `@behaviour` dispatch on the struct's own module) and whatever
  configuration/collaborators that module needs (e.g. a cache root and an
  injected fetcher fun or module). Callers never pattern-match on the
  struct's internals — they hold it opaquely and pass it back into this
  port's functions.

  The fetcher itself is a dependency injected into the adapter, not into
  this port: this keeps `ActionProxy` implementations substitutable
  (Liskov Substitution) regardless of which fetch strategy — a local
  fixture directory in tests and this slice, `codeload.github.com` in a
  later phase — they wrap.
  """

  @typedoc "An opaque handle identifying an ActionProxy implementation and its configuration."
  @type proxy :: struct()

  @typedoc "An action's repository identifier, e.g. \"actions/checkout\"."
  @type repo :: String.t()

  @typedoc "The ref to resolve — a tag, branch, or commit SHA as given by the workflow."
  @type ref :: String.t()

  @typedoc "Absolute or relative filesystem path to the resolved tarball."
  @type tarball_path :: String.t()

  @doc """
  Resolve `(repo, ref)` to the local path of its tarball, fetching it if
  and only if this is the first-ever resolve of that exact pair.
  """
  @callback resolve(proxy, repo, ref) :: {:ok, tarball_path} | {:error, term()}

  @doc """
  Resolve `(repo, ref)` to the local path of its tarball.

  Dispatches to whichever module the `proxy` struct belongs to — callers
  depend on this port module, never on a concrete adapter (Dependency
  Inversion).
  """
  @spec resolve(proxy, repo, ref) :: {:ok, tarball_path} | {:error, term()}
  def resolve(%module{} = proxy, repo, ref) when is_binary(repo) and is_binary(ref) do
    module.resolve(proxy, repo, ref)
  end
end
