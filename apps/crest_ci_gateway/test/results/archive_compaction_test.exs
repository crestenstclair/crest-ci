defmodule CrestCiGateway.Results.ArchiveCompactionTest do
  @moduledoc """
  Cross-component behavioral proof for the Results archive-compaction path
  (`asset.ArchiveCompactionTest`): `applicationService.Gateway.LogIngest`
  ingests a job's log chunks across several steps -- delivered OUT OF
  ORDER, with ~20% of them re-sent as duplicates -- and
  `domainService.Results.LogCompactor` (exercised both directly and via
  `applicationService.Results.ArchiveOnComplete`, the gateway's job
  completion hook) compacts them into a single durable, gapless,
  exactly-once archive.

  `ArchiveOnComplete.archive/3` is run TWICE against the same job to prove
  the completion path is a true no-op the second time -- identical
  archive, no double-processing -- and that the job's live chunks are gone
  once archived, per its "safe to re-run" contract.
  """

  use ExUnit.Case, async: true

  alias CrestCiContract.WorkflowRunStatus
  alias CrestCiGateway.BlobStore
  alias CrestCiGateway.LocalFsBlobStore
  alias CrestCiGateway.LogArchive
  alias CrestCiGateway.LogChunk
  alias CrestCiGateway.LogIngest
  alias CrestCiGateway.Results.ArchiveOnComplete
  alias CrestCiGateway.Results.LogCompactor
  alias CrestCiGateway.Test.FakeKubeClient

  @gvk {"ci.crest.dev", "v1alpha1", "WorkflowRun"}
  @namespace "default"
  @job_key "archive-compaction-job"
  @run "run-archive-compaction-1"

  # (step, max_seq) -- seqs run 1..max_seq within each step, per this
  # asset's "within each step seqs are 1..max in order" contract.
  @steps [{"build", 5}, {"deploy", 3}, {"test", 4}]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "archive_compaction_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    store = LocalFsBlobStore.new(root)
    ingest_deps = %LogIngest.Deps{blob_store: store, run: @run}

    {:ok, kube_pid} = FakeKubeClient.start_link()
    kube_conn = {FakeKubeClient, kube_pid}

    workflow_run_seed = %{
      "metadata" => %{"name" => "run-archive-1", "namespace" => @namespace},
      "spec" => %{},
      "status" => WorkflowRunStatus.to_wire(WorkflowRunStatus.new())
    }

    {:ok, workflow_run} = FakeKubeClient.create(kube_pid, @gvk, @namespace, workflow_run_seed)

    %{
      store: store,
      ingest_deps: ingest_deps,
      kube_conn: kube_conn,
      workflow_run: workflow_run
    }
  end

  test "duplicated, reordered chunk ingest compacts into one gapless, exactly-once archive -- idempotently, live chunks gone after",
       %{
         store: store,
         ingest_deps: ingest_deps,
         kube_conn: kube_conn,
         workflow_run: workflow_run
       } do
    all_sent = ingest_all_chunks_reordered_with_duplicates(ingest_deps)

    sent_chunks =
      for {job_key, step, seq, content} <- all_sent do
        {:ok, chunk} = LogChunk.new(job_key, step, seq, content)
        chunk
      end

    # -- Reconstruct via the real, pure LogCompactor.plan/2 -----------------
    # every (step, seq) chunk this test attempted to send -- including the
    # duplicate resends -- fed through the same planning step
    # ArchiveOnComplete relies on internally.
    {ordered, _content} = LogCompactor.plan(@job_key, sent_chunks)

    distinct_expected = Enum.reduce(@steps, 0, fn {_step, max_seq}, acc -> acc + max_seq end)

    archived_lines = length(ordered)
    duplicate_lines = archived_lines - length(Enum.uniq_by(ordered, &{&1.step, &1.seq}))
    order_violations = count_order_violations(ordered)

    # -- Exercise the compaction domain service directly, twice -------------
    compactor_deps = %LogCompactor.Deps{blob_store: store, run: @run}

    assert {:ok, %LogArchive{} = plan_archive_1, deletion_1} =
             LogCompactor.compact(compactor_deps, @job_key, nil, sent_chunks)

    assert length(deletion_1) == distinct_expected

    assert {:ok, ^plan_archive_1, []} =
             LogCompactor.compact(compactor_deps, @job_key, plan_archive_1, sent_chunks)

    # -- Exercise the full completion path: ArchiveOnComplete ---------------
    # This is the gateway's actual job-completion hook: it runs
    # LogCompactor, records the LogArchive pointer via StatusProjector, and
    # deletes the job's live chunks. Run it TWICE to prove idempotency end
    # to end (not just at the LogCompactor layer above).
    archive_deps = %ArchiveOnComplete.Deps{blob_store: store, run: @run, kube_conn: kube_conn}

    assert {:ok, %LogArchive{} = archive_1} =
             ArchiveOnComplete.archive(archive_deps, workflow_run, @job_key)

    # Live chunks are gone once the job has been archived.
    assert {:ok, ""} = BlobStore.read_log(store, @run, @job_key)

    assert {:ok, %LogArchive{} = archive_2} =
             ArchiveOnComplete.archive(archive_deps, workflow_run, @job_key)

    idempotent? = archive_1 == archive_2

    IO.puts(
      "archived_lines=#{archived_lines} duplicate_lines=#{duplicate_lines} " <>
        "order_violations=#{order_violations} idempotent=#{idempotent?}"
    )

    assert archived_lines == distinct_expected
    assert duplicate_lines == 0
    assert order_violations == 0
    assert idempotent?
  end

  # -- fixtures --------------------------------------------------------------

  # Ingests every (step, seq) chunk declared in @steps via the real
  # LogIngest.ingest_chunk/5: each step delivered in DESCENDING seq order
  # (out-of-order relative to true upload order) and interleaved
  # round-robin across steps, followed by a second pass re-sending three
  # chunks (~20% of the twelve distinct chunks) with DIFFERENT content --
  # simulating a runner retry across a gateway replica failover. Returns
  # every (job_key, step, seq, content) tuple actually sent, in send
  # order, including the duplicates, so callers can feed the exact same
  # attempted-send history into LogCompactor.plan/2.
  defp ingest_all_chunks_reordered_with_duplicates(ingest_deps) do
    per_step_descending =
      Enum.map(@steps, fn {step, max_seq} ->
        for seq <- max_seq..1//-1, do: {@job_key, step, seq, "#{step}:#{seq}\n"}
      end)

    reordered = round_robin(per_step_descending)

    duplicates = [
      {@job_key, "build", 1, "DUPLICATE-build:1\n"},
      {@job_key, "test", 2, "DUPLICATE-test:2\n"},
      {@job_key, "deploy", 1, "DUPLICATE-deploy:1\n"}
    ]

    all_sends = reordered ++ duplicates

    Enum.each(all_sends, fn {job_key, step, seq, content} ->
      assert :ok = LogIngest.ingest_chunk(ingest_deps, job_key, step, seq, content)
    end)

    all_sends
  end

  # Interleaves several lists round-robin: one element from each remaining
  # non-empty list, in turn, until all are exhausted.
  defp round_robin([]), do: []

  defp round_robin(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] ->
        []

      non_empty ->
        heads = Enum.map(non_empty, &hd/1)
        tails = Enum.map(non_empty, &tl/1)
        heads ++ round_robin(tails)
    end
  end

  defp count_order_violations(ordered) do
    ordered
    |> Enum.group_by(& &1.step)
    |> Enum.reduce(0, fn {_step, chunks}, acc ->
      seqs = Enum.map(chunks, & &1.seq)
      expected = Enum.to_list(1..length(seqs))

      violations =
        seqs
        |> Enum.zip(expected)
        |> Enum.count(fn {actual, expected_seq} -> actual != expected_seq end)

      acc + violations
    end)
  end
end
