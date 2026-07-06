defmodule SimRunner.Demo.LogVerifierTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.LocalFsBlobStore
  alias SimRunner.Demo.LogVerifier

  setup do
    root = Path.join(System.tmp_dir!(), "log_verifier_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, store: LocalFsBlobStore.new(root)}
  end

  test "gapless=true and the exact total count when every step is 1..max with no gaps", %{
    root: root,
    store: store
  } do
    for seq <- 1..5,
        do: LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", seq, "x")

    for seq <- 1..3, do: LocalFsBlobStore.append_chunk(store, "run-1", "build", "unit", seq, "x")

    assert LogVerifier.verify(root, "run-1", ["build"]) == {true, 8}
  end

  test "gapless=false when a step is missing a sequence number", %{root: root, store: store} do
    LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", 1, "x")
    LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", 3, "x")

    assert {false, 2} = LogVerifier.verify(root, "run-1", ["build"])
  end

  test "a resent (idempotent) chunk never inflates the count or breaks gaplessness", %{
    root: root,
    store: store
  } do
    LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", 1, "first")
    LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", 1, "resend-after-reconnect")
    LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", 2, "second")

    assert LogVerifier.verify(root, "run-1", ["build"]) == {true, 2}
  end

  test "gapless=false and zero count when a job directory never received any chunks", %{
    root: root
  } do
    assert LogVerifier.verify(root, "run-1", ["never-ran"]) == {false, 0}
  end

  test "sums across multiple jobs, gapless only when every job is gapless", %{
    root: root,
    store: store
  } do
    for seq <- 1..4,
        do: LocalFsBlobStore.append_chunk(store, "run-1", "build", "compile", seq, "x")

    for seq <- 1..2,
        do: LocalFsBlobStore.append_chunk(store, "run-1", "test-a", "compile", seq, "x")

    assert LogVerifier.verify(root, "run-1", ["build", "test-a"]) == {true, 6}

    LocalFsBlobStore.append_chunk(store, "run-1", "test-b", "compile", 2, "x")
    assert {false, 7} = LogVerifier.verify(root, "run-1", ["build", "test-a", "test-b"])
  end
end
