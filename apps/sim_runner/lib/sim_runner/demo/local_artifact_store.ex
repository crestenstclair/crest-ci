defmodule SimRunner.Demo.LocalArtifactStore do
  @moduledoc """
  Minimal filesystem-backed artifact store for the results E2E demo:
  `put/4` writes an artifact's full content to a deterministic path
  derived from `(run, name)`; `get/3` reads it back. Digest computation
  (`digest/1`) is pure and content-addressed (hex-encoded SHA-256), so a
  caller can prove byte-identical round-tripping by comparing digests
  alone, never by trusting a client-side counter.

  Deliberately filesystem-backed, not ETS/Agent-backed: this mirrors
  `CrestCiGateway.LocalFsBlobStore`'s own approach to demo-harness
  storage (deterministic paths, no in-process authoritative state), so
  this demo's artifact truth is reconstructable from disk exactly like
  every other authoritative store in this project — nothing here is a
  source of truth two components must agree on in memory.

  This is deliberately a demo-scoped stand-in rather than a caller of
  `port.Results.ArtifactStore` (`CrestCiGateway.Results.ArtifactStore`,
  in `crest_ci_gateway`): `sim_runner` cannot declare a compile-time
  dependency on `crest_ci_gateway` at all (it already test-depends on
  `sim_runner`, which would create a cycle), and this demo's own
  artifact round-trip has no reason to couple itself to that context's
  adapter/wire-format choices. `mix crest_ci.demo_results` needs a
  real, working artifact round-trip; this small adapter provides it
  directly, owned entirely by this demo.
  """

  @doc "Write `content` for artifact `name` produced by `run`, rooted at `root`."
  @spec put(String.t(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put(root, run, name, content)
      when is_binary(root) and is_binary(run) and is_binary(name) and is_binary(content) do
    path = artifact_path(root, run, name)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  @doc "Read back the content previously `put/4` for `(run, name)`."
  @spec get(String.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(root, run, name) when is_binary(root) and is_binary(run) and is_binary(name) do
    case File.read(artifact_path(root, run, name)) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc """
  Hex-encoded (lowercase) SHA-256 digest of `content`. Pure and
  deterministic — identical content always yields identical digest,
  which is what makes a round-trip verifiable by digest comparison
  alone.
  """
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp artifact_path(root, run, name) do
    Path.join([root, "artifacts", run, name])
  end
end
