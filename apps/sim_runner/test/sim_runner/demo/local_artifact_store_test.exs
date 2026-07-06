defmodule SimRunner.Demo.LocalArtifactStoreTest do
  use ExUnit.Case, async: true

  alias SimRunner.Demo.LocalArtifactStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "artifact_store_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "round-trips content byte-identically, verified by digest comparison", %{root: root} do
    content = :crypto.strong_rand_bytes(1024)

    assert :ok = LocalArtifactStore.put(root, "run-1", "out.bin", content)
    assert {:ok, downloaded} = LocalArtifactStore.get(root, "run-1", "out.bin")
    assert downloaded == content
    assert LocalArtifactStore.digest(downloaded) == LocalArtifactStore.digest(content)
  end

  test "digest/1 is a deterministic lowercase-hex sha256" do
    digest = LocalArtifactStore.digest("hello")
    assert String.length(digest) == 64
    assert digest == String.downcase(digest)
    assert digest == LocalArtifactStore.digest("hello")
  end

  test "reading an artifact that was never put returns not_found", %{root: root} do
    assert {:error, :not_found} = LocalArtifactStore.get(root, "run-1", "missing.bin")
  end

  test "different runs with the same artifact name never collide", %{root: root} do
    assert :ok = LocalArtifactStore.put(root, "run-1", "out.bin", "one")
    assert :ok = LocalArtifactStore.put(root, "run-2", "out.bin", "two")

    assert {:ok, "one"} = LocalArtifactStore.get(root, "run-1", "out.bin")
    assert {:ok, "two"} = LocalArtifactStore.get(root, "run-2", "out.bin")
  end
end
