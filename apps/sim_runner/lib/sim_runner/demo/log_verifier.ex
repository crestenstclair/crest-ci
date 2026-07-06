defmodule SimRunner.Demo.LogVerifier do
  @moduledoc """
  Authoritative log-completeness verification for the E2E demo.

  Reconstructs each job's ingested chunks directly from
  `CrestCiGateway.LocalFsBlobStore`'s own on-disk layout
  (`<root>/<run>/<job>/<step>/<seq>.chunk` — one file per chunk) rather
  than from any client-side counter, and checks every step's chunk
  sequence numbers are exactly `1..max`, with no gaps. Duplicated content
  is structurally impossible to observe here: `LocalFsBlobStore.append_chunk/6`
  opens each chunk file `:exclusive`, so a resend of an already-stored
  `(step, seq)` is a guaranteed no-op — counting distinct files IS
  counting distinct chunks.
  """

  @doc """
  For every name in `job_names` under `root/run_id`, checks every step
  directory's chunk sequence numbers form exactly `1..count` with no
  gaps. Returns `{gapless?, total_chunk_count}` — `gapless?` is `false`
  if any job or step is missing entirely, since a job with zero observed
  chunks is not a completed, gapless log.
  """
  @spec verify(String.t(), String.t(), [String.t()]) :: {boolean(), non_neg_integer()}
  def verify(root, run_id, job_names) do
    Enum.reduce(job_names, {true, 0}, fn job_name, {gapless_acc, total_acc} ->
      {job_gapless?, job_count} = verify_job(root, run_id, job_name)
      {gapless_acc and job_gapless?, total_acc + job_count}
    end)
  end

  defp verify_job(root, run_id, job_name) do
    job_dir = Path.join([root, run_id, job_name])

    case File.ls(job_dir) do
      {:ok, steps} when steps != [] ->
        Enum.reduce(steps, {true, 0}, fn step, {gapless_acc, total_acc} ->
          {step_gapless?, step_count} = verify_step(Path.join(job_dir, step))
          {gapless_acc and step_gapless?, total_acc + step_count}
        end)

      _empty_or_missing ->
        {false, 0}
    end
  end

  defp verify_step(step_dir) do
    case File.ls(step_dir) do
      {:ok, files} ->
        seqs =
          files
          |> Enum.map(&parse_seq/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        {gapless?(seqs), length(seqs)}

      {:error, _reason} ->
        {false, 0}
    end
  end

  defp gapless?([]), do: false
  defp gapless?(seqs), do: seqs == Enum.to_list(1..length(seqs))

  @seq_pattern ~r/^(\d+)\.chunk$/

  defp parse_seq(filename) do
    case Regex.run(@seq_pattern, filename) do
      [_, seq_str] -> String.to_integer(seq_str)
      _no_match -> nil
    end
  end
end
