defmodule CrestCiGateway.LogArchiveTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.LogArchive

  describe "new/4" do
    test "builds a valid LogArchive from well-shaped values" do
      assert {:ok, %LogArchive{} = archive} =
               LogArchive.new("build", "runs/01H.../build.log", 4096, 128)

      assert archive.job_key == "build"
      assert archive.run_ref == "runs/01H.../build.log"
      assert archive.byte_size == 4096
      assert archive.line_count == 128
    end

    test "accepts a zero byte_size and line_count (empty compacted log)" do
      assert {:ok, %LogArchive{byte_size: 0, line_count: 0}} =
               LogArchive.new("build", "runs/01H.../build.log", 0, 0)
    end

    test "rejects a non-binary job_key" do
      assert {:error, :invalid_log_archive} = LogArchive.new(nil, "ref", 1, 1)
      assert {:error, :invalid_log_archive} = LogArchive.new(123, "ref", 1, 1)
    end

    test "rejects an empty job_key" do
      assert {:error, :invalid_log_archive} = LogArchive.new("", "ref", 1, 1)
    end

    test "rejects a non-binary or empty run_ref" do
      assert {:error, :invalid_log_archive} = LogArchive.new("build", nil, 1, 1)
      assert {:error, :invalid_log_archive} = LogArchive.new("build", "", 1, 1)
    end

    test "rejects a negative byte_size" do
      assert {:error, :invalid_log_archive} = LogArchive.new("build", "ref", -1, 1)
    end

    test "rejects a non-integer byte_size" do
      assert {:error, :invalid_log_archive} = LogArchive.new("build", "ref", "4096", 1)
    end

    test "rejects a negative line_count" do
      assert {:error, :invalid_log_archive} = LogArchive.new("build", "ref", 1, -1)
    end

    test "rejects a non-integer line_count" do
      assert {:error, :invalid_log_archive} = LogArchive.new("build", "ref", 1, "128")
    end
  end

  describe "digest/1" do
    test "is deterministic for identical content" do
      assert LogArchive.digest("hello world") == LogArchive.digest("hello world")
    end

    test "differs for differing content" do
      refute LogArchive.digest("hello world") == LogArchive.digest("goodbye world")
    end

    test "returns a lowercase hex-encoded sha256 (64 hex chars)" do
      digest = LogArchive.digest("hello world")

      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end

    test "matches a known sha256 vector for an empty binary" do
      assert LogArchive.digest("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end
  end

  describe "to_wire/1 and from_wire/1 round-trip" do
    test "round-trips through the wire map" do
      {:ok, archive} = LogArchive.new("test/m-3f9a2c", "runs/01H.../test.log", 2048, 64)

      wire = LogArchive.to_wire(archive)

      assert wire == %{
               "jobKey" => "test/m-3f9a2c",
               "runRef" => "runs/01H.../test.log",
               "byteSize" => 2048,
               "lineCount" => 64
             }

      assert {:ok, ^archive} = LogArchive.from_wire(wire)
    end

    test "from_wire rejects a map missing a required field" do
      wire = %{"jobKey" => "build", "runRef" => "ref", "byteSize" => 0}
      assert {:error, :invalid_log_archive} = LogArchive.from_wire(wire)
    end

    test "from_wire rejects a map with a wrongly-typed field" do
      wire = %{
        "jobKey" => "build",
        "runRef" => "ref",
        "byteSize" => "0",
        "lineCount" => 0
      }

      assert {:error, :invalid_log_archive} = LogArchive.from_wire(wire)
    end

    test "from_wire rejects a non-map" do
      assert {:error, :invalid_log_archive} = LogArchive.from_wire("not a map")
    end
  end
end
