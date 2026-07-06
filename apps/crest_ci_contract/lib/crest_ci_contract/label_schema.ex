defmodule CrestCiContract.LabelSchema do
  @moduledoc """
  Builds and parses the `crest.dev/*` label set that components use to
  filter Kubernetes custom resources instead of parsing their names.

  Every child resource created for a run carries four labels:

    * `crest.dev/run-ulid` — the owning `WorkflowRun`'s `Ulid`, verbatim.
    * `crest.dev/job-key` — the `JobKey` slug (`CrestCiContract.JobKey.slug/1`),
      since raw job keys may contain characters (like `/`) that are not
      valid in a Kubernetes label value.
    * `crest.dev/runs-on-hash` — a deterministic digest of the job's
      `runsOn` list, since label values are single strings and cannot carry
      a list directly. `runs_on_hash/1` sorts the list before hashing, so
      the same *set* of runner tags always yields the same label value
      regardless of the order callers pass them in.
    * `crest.dev/cluster` — the target cluster name, verbatim.

  `build_labels/4` and `parse_labels/1` are pure and total over well-formed
  input: `build_labels/4` always returns a map with exactly these four
  `crest.dev/*` keys and no others, and `parse_labels/1` is its left
  inverse for the fields that survive the label encoding unchanged
  (`run_ulid`, `cluster`) and for the derived fields it can still recover
  losslessly for comparison purposes (`job_key` as its slug, `runs_on` as
  its hash) — round-tripping through `build_labels/4` then `parse_labels/1`
  reproduces the same slug/hash a caller would get by slugging/hashing the
  original values directly.

  This module has no side effects and holds no state of its own — it is a
  pure derivation over data already living in a custom resource's
  `ObjectMeta.labels`, consistent with the project invariant that no truth
  lives outside the resource store.
  """

  alias CrestCiContract.JobKey

  @run_ulid_label "crest.dev/run-ulid"
  @job_key_label "crest.dev/job-key"
  @runs_on_hash_label "crest.dev/runs-on-hash"
  @cluster_label "crest.dev/cluster"

  @label_keys [@run_ulid_label, @job_key_label, @runs_on_hash_label, @cluster_label]

  @typedoc "The parsed, structured view of a `crest.dev/*` label set."
  @type parsed :: %{
          run_ulid: String.t(),
          job_key: String.t(),
          runs_on_hash: String.t(),
          cluster: String.t()
        }

  @doc """
  All `crest.dev/*` label keys this schema owns, in the order they appear
  conceptually (not necessarily map iteration order). Exposed so callers
  and tests can assert exhaustively that `build_labels/4` never emits an
  unexpected key.
  """
  @spec label_keys() :: [String.t()]
  def label_keys, do: @label_keys

  @doc """
  Build the `crest.dev/*` label map for a run's child resource from its
  run `Ulid`, `JobKey`, `runsOn` list, and target cluster name.

  `job_key` is slugged via `CrestCiContract.JobKey.slug/1` before being
  stored, since raw job keys (e.g. `"test/m-3f9a2c"`) are not valid
  Kubernetes label values. `runs_on` is hashed via `runs_on_hash/1` since a
  label value cannot carry a list.

  Pure and deterministic: identical inputs always yield an identical map,
  and every key in the result is `crest.dev/*`-prefixed.
  """
  @spec build_labels(String.t(), JobKey.t(), [String.t()], String.t()) :: %{
          String.t() => String.t()
        }
  def build_labels(run_ulid, job_key, runs_on, cluster)
      when is_binary(run_ulid) and is_binary(job_key) and is_list(runs_on) and
             is_binary(cluster) do
    %{
      @run_ulid_label => run_ulid,
      @job_key_label => JobKey.slug(job_key),
      @runs_on_hash_label => runs_on_hash(runs_on),
      @cluster_label => cluster
    }
  end

  @doc """
  Deterministic digest of a `runsOn` tag list, suitable for use as a
  Kubernetes label value.

  The list is sorted before hashing so that two `runsOn` lists containing
  the same tags in a different order hash identically — callers filter by
  "which runner tags does this job need", not by declaration order. The
  digest is a lowercase hex SHA-256 prefix, which is always non-empty,
  alphanumeric, and within the 63-character Kubernetes label value limit.
  """
  @spec runs_on_hash([String.t()]) :: String.t()
  def runs_on_hash(runs_on) when is_list(runs_on) do
    runs_on
    |> Enum.sort()
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Parse a `crest.dev/*` label map back into its structured fields.

  Returns `{:error, :missing_labels}` when any of the four expected keys
  is absent, so callers can distinguish a malformed/partial label set from
  a successfully parsed one rather than getting a map with `nil`s. Extra,
  unrelated keys on the input map (e.g. other `ObjectMeta.labels` entries)
  are ignored.
  """
  @spec parse_labels(%{String.t() => String.t()}) :: {:ok, parsed()} | {:error, :missing_labels}
  def parse_labels(labels) when is_map(labels) do
    with {:ok, run_ulid} <- fetch_label(labels, @run_ulid_label),
         {:ok, job_key} <- fetch_label(labels, @job_key_label),
         {:ok, runs_on_digest} <- fetch_label(labels, @runs_on_hash_label),
         {:ok, cluster} <- fetch_label(labels, @cluster_label) do
      {:ok,
       %{
         run_ulid: run_ulid,
         job_key: job_key,
         runs_on_hash: runs_on_digest,
         cluster: cluster
       }}
    end
  end

  defp fetch_label(labels, key) do
    case Map.fetch(labels, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_labels}
    end
  end
end
