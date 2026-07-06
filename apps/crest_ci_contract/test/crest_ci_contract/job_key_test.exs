defmodule CrestCiContract.JobKeyTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.JobKey

  describe "new/1" do
    test "accepts a non-empty binary" do
      assert {:ok, "build"} = JobKey.new("build")
      assert {:ok, "test/m-3f9a2c"} = JobKey.new("test/m-3f9a2c")
    end

    test "rejects an empty binary" do
      assert {:error, :invalid_job_key} = JobKey.new("")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_job_key} = JobKey.new(nil)
      assert {:error, :invalid_job_key} = JobKey.new(:build)
      assert {:error, :invalid_job_key} = JobKey.new(123)
    end
  end

  describe "slug/1" do
    test "lowercases the job key" do
      assert JobKey.slug("Build") == "build"
      assert JobKey.slug("BUILD") == "build"
    end

    test "replaces / with -" do
      assert JobKey.slug("test/m-3f9a2c") == "test-m-3f9a2c"
      assert JobKey.slug("a/b/c") == "a-b-c"
    end

    test "restricts output to [a-z0-9-]" do
      slugged = JobKey.slug("Test/Job_With Spaces!@#")

      assert slugged
             |> String.to_charlist()
             |> Enum.all?(fn c ->
               (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9) or c == ?-
             end)
    end

    test "is pure and deterministic across repeated invocations" do
      job_key = "test/m-3f9a2c"
      assert JobKey.slug(job_key) == JobKey.slug(job_key)
      assert Enum.uniq(for _ <- 1..10, do: JobKey.slug(job_key)) == [JobKey.slug(job_key)]
    end

    test "simple job keys with no special characters slug to themselves" do
      assert JobKey.slug("build") == "build"
    end
  end
end
