defmodule CrestCiGateway.Results.ArtifactNameTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ArtifactName

  describe "new/1" do
    test "accepts a non-empty binary" do
      assert {:ok, "coverage.html"} = ArtifactName.new("coverage.html")
      assert {:ok, "dist/app.tar.gz"} = ArtifactName.new("dist/app.tar.gz")
    end

    test "rejects an empty binary" do
      assert {:error, :invalid_artifact_name} = ArtifactName.new("")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_artifact_name} = ArtifactName.new(nil)
      assert {:error, :invalid_artifact_name} = ArtifactName.new(:artifact)
      assert {:error, :invalid_artifact_name} = ArtifactName.new(123)
    end

    test "rejects a leading slash" do
      assert {:error, :invalid_artifact_name} = ArtifactName.new("/etc/passwd")
    end

    test "rejects path traversal segments" do
      assert {:error, :invalid_artifact_name} = ArtifactName.new("../secret")
      assert {:error, :invalid_artifact_name} = ArtifactName.new("dist/../../secret")
      assert {:error, :invalid_artifact_name} = ArtifactName.new("..")
    end
  end

  describe "safe_key/1" do
    test "replaces / with -" do
      assert ArtifactName.safe_key("dist/app.tar.gz") == "dist-app.tar.gz"
      assert ArtifactName.safe_key("a/b/c") == "a-b-c"
    end

    test "restricts output to [a-zA-Z0-9._-]" do
      safe = ArtifactName.safe_key("Report (final)!@#.html")

      assert safe
             |> String.to_charlist()
             |> Enum.all?(fn c ->
               (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or
                 c == ?. or c == ?_ or c == ?-
             end)
    end

    test "is pure and deterministic across repeated invocations" do
      name = "dist/app.tar.gz"
      assert ArtifactName.safe_key(name) == ArtifactName.safe_key(name)

      assert Enum.uniq(for _ <- 1..10, do: ArtifactName.safe_key(name)) == [
               ArtifactName.safe_key(name)
             ]
    end

    test "simple names with no special characters key to themselves" do
      assert ArtifactName.safe_key("coverage.html") == "coverage.html"
    end
  end
end
