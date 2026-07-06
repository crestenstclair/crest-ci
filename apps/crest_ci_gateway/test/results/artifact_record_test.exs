defmodule CrestCiGateway.Results.ArtifactRecordTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ArtifactRecord

  @valid_digest ArtifactRecord.digest("hello world")
  @valid_timestamp "2026-07-05T12:00:00Z"

  describe "digest/1" do
    test "computes a hex-encoded SHA-256 of the content" do
      digest = ArtifactRecord.digest("hello world")

      assert digest ==
               :crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower)
    end

    test "is pure and deterministic across repeated invocations" do
      assert ArtifactRecord.digest("same content") == ArtifactRecord.digest("same content")
    end

    test "differs for different content" do
      refute ArtifactRecord.digest("a") == ArtifactRecord.digest("b")
    end
  end

  describe "new/6" do
    test "builds a record from valid fields" do
      assert {:ok, record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 1024
               )

      assert record.digest == @valid_digest
      assert record.finalized_at == @valid_timestamp
      assert record.job_key == "build"
      assert record.name == "coverage.html"
      assert record.run_ref == "run-01hqz"
      assert record.size_bytes == 1024
    end

    test "rejects a digest that is not 64 lowercase hex chars" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 "not-a-digest",
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 1024
               )
    end

    test "rejects an uppercase-hex digest" do
      upper = String.upcase(@valid_digest)

      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 upper,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 1024
               )
    end

    test "rejects an unparseable finalized_at timestamp" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 "not-a-timestamp",
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 1024
               )
    end

    test "rejects an empty job_key" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "",
                 "coverage.html",
                 "run-01hqz",
                 1024
               )
    end

    test "rejects an invalid artifact name (path traversal)" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "../secret",
                 "run-01hqz",
                 1024
               )
    end

    test "rejects an empty run_ref" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "",
                 1024
               )
    end

    test "rejects a negative size_bytes" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 -1
               )
    end

    test "accepts a zero size_bytes (empty artifact is valid)" do
      assert {:ok, record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 0
               )

      assert record.size_bytes == 0
    end

    test "rejects non-integer size_bytes" do
      assert {:error, :invalid_artifact_record} =
               ArtifactRecord.new(
                 @valid_digest,
                 @valid_timestamp,
                 "build",
                 "coverage.html",
                 "run-01hqz",
                 "1024"
               )
    end
  end

  describe "key/1" do
    test "returns the (run_ref, job_key, name) identity tuple" do
      {:ok, record} =
        ArtifactRecord.new(
          @valid_digest,
          @valid_timestamp,
          "build",
          "coverage.html",
          "run-01hqz",
          1024
        )

      assert ArtifactRecord.key(record) == {"run-01hqz", "build", "coverage.html"}
    end

    test "two records built from identical fields have equal keys" do
      {:ok, record_a} =
        ArtifactRecord.new(
          @valid_digest,
          @valid_timestamp,
          "build",
          "coverage.html",
          "run-01hqz",
          1024
        )

      {:ok, record_b} =
        ArtifactRecord.new(
          @valid_digest,
          "2026-07-05T13:00:00Z",
          "build",
          "coverage.html",
          "run-01hqz",
          2048
        )

      assert ArtifactRecord.key(record_a) == ArtifactRecord.key(record_b)
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips through the wire format" do
      {:ok, record} =
        ArtifactRecord.new(
          @valid_digest,
          @valid_timestamp,
          "build",
          "dist/app.tar.gz",
          "run-01hqz",
          4096
        )

      wire = ArtifactRecord.to_wire(record)

      assert wire == %{
               "digest" => @valid_digest,
               "finalizedAt" => @valid_timestamp,
               "jobKey" => "build",
               "name" => "dist/app.tar.gz",
               "runRef" => "run-01hqz",
               "sizeBytes" => 4096
             }

      assert {:ok, ^record} = ArtifactRecord.from_wire(wire)
    end

    test "from_wire rejects a map missing a required field" do
      wire =
        %{
          "digest" => @valid_digest,
          "finalizedAt" => @valid_timestamp,
          "jobKey" => "build",
          "name" => "coverage.html",
          "runRef" => "run-01hqz"
        }

      assert {:error, :invalid_artifact_record} = ArtifactRecord.from_wire(wire)
    end

    test "from_wire rejects a map with a wrong-typed field" do
      wire = %{
        "digest" => @valid_digest,
        "finalizedAt" => @valid_timestamp,
        "jobKey" => "build",
        "name" => "coverage.html",
        "runRef" => "run-01hqz",
        "sizeBytes" => "not-an-integer"
      }

      assert {:error, :invalid_artifact_record} = ArtifactRecord.from_wire(wire)
    end

    test "from_wire rejects non-map input" do
      assert {:error, :invalid_artifact_record} = ArtifactRecord.from_wire("not-a-map")
    end
  end
end
