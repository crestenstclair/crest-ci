defmodule CrestCiGateway.LogChunkTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.LogChunk

  describe "new/4" do
    test "builds a valid LogChunk from well-shaped values" do
      assert {:ok, %LogChunk{} = chunk} = LogChunk.new("build", "compile", 0, "hello world")
      assert chunk.job_key == "build"
      assert chunk.step == "compile"
      assert chunk.seq == 0
      assert chunk.content == "hello world"
    end

    test "accepts an empty content binary" do
      assert {:ok, %LogChunk{content: ""}} = LogChunk.new("build", "compile", 3, "")
    end

    test "rejects a non-binary job_key" do
      assert {:error, :invalid_log_chunk} = LogChunk.new(nil, "compile", 0, "x")
      assert {:error, :invalid_log_chunk} = LogChunk.new(123, "compile", 0, "x")
    end

    test "rejects an empty job_key" do
      assert {:error, :invalid_log_chunk} = LogChunk.new("", "compile", 0, "x")
    end

    test "rejects a non-binary or empty step" do
      assert {:error, :invalid_log_chunk} = LogChunk.new("build", nil, 0, "x")
      assert {:error, :invalid_log_chunk} = LogChunk.new("build", "", 0, "x")
    end

    test "rejects a negative seq" do
      assert {:error, :invalid_log_chunk} = LogChunk.new("build", "compile", -1, "x")
    end

    test "rejects a non-integer seq" do
      assert {:error, :invalid_log_chunk} = LogChunk.new("build", "compile", "0", "x")
    end

    test "rejects non-binary content" do
      assert {:error, :invalid_log_chunk} = LogChunk.new("build", "compile", 0, 123)
    end
  end

  describe "key/1" do
    test "returns the (job_key, step, seq) idempotency key" do
      {:ok, chunk} = LogChunk.new("build", "compile", 7, "content")
      assert LogChunk.key(chunk) == {"build", "compile", 7}
    end

    test "two chunks with the same (job_key, step, seq) but different content share a key" do
      {:ok, first} = LogChunk.new("build", "compile", 7, "first upload")
      {:ok, resend} = LogChunk.new("build", "compile", 7, "first upload")

      assert LogChunk.key(first) == LogChunk.key(resend)
    end

    test "differing seq yields differing keys" do
      {:ok, a} = LogChunk.new("build", "compile", 1, "x")
      {:ok, b} = LogChunk.new("build", "compile", 2, "x")

      refute LogChunk.key(a) == LogChunk.key(b)
    end
  end

  describe "to_wire/1 and from_wire/1 round-trip" do
    test "round-trips through the wire map" do
      {:ok, chunk} = LogChunk.new("test/m-3f9a2c", "run tests", 42, "PASS: 12 tests\n")

      wire = LogChunk.to_wire(chunk)

      assert wire == %{
               "jobKey" => "test/m-3f9a2c",
               "step" => "run tests",
               "seq" => 42,
               "content" => "PASS: 12 tests\n"
             }

      assert {:ok, ^chunk} = LogChunk.from_wire(wire)
    end

    test "from_wire rejects a map missing a required field" do
      wire = %{"jobKey" => "build", "step" => "compile", "seq" => 0}
      assert {:error, :invalid_log_chunk} = LogChunk.from_wire(wire)
    end

    test "from_wire rejects a map with a wrongly-typed field" do
      wire = %{"jobKey" => "build", "step" => "compile", "seq" => "0", "content" => "x"}
      assert {:error, :invalid_log_chunk} = LogChunk.from_wire(wire)
    end

    test "from_wire rejects a non-map" do
      assert {:error, :invalid_log_chunk} = LogChunk.from_wire("not a map")
    end
  end
end
