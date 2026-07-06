defmodule CrestCiContract.DeterministicNamingTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.DeterministicNaming
  alias CrestCiContract.Ulid

  describe "runner_job_name/2" do
    test "follows the pattern run-<ulid>-j-<slugged jobKey>" do
      ulid = Ulid.generate(0, <<0::80>>)

      assert DeterministicNaming.runner_job_name(ulid, "build") ==
               "run-" <> ulid <> "-j-build"
    end

    test "slugs the job key: lowercases, replaces / with -, restricts charset" do
      ulid = Ulid.generate(0, <<0::80>>)

      assert DeterministicNaming.runner_job_name(ulid, "Test/M-3f9a2c") ==
               "run-" <> ulid <> "-j-test-m-3f9a2c"
    end

    test "is pure and deterministic: identical inputs always yield an identical output" do
      ulid = Ulid.generate()
      job_key = "test/m-3f9a2c"

      results = for _ <- 1..25, do: DeterministicNaming.runner_job_name(ulid, job_key)

      assert Enum.uniq(results) == [List.first(results)]
    end

    test "different job keys under the same ulid produce different names" do
      ulid = Ulid.generate()

      refute DeterministicNaming.runner_job_name(ulid, "build") ==
               DeterministicNaming.runner_job_name(ulid, "test")
    end

    test "different ulids under the same job key produce different names" do
      ulid_a = Ulid.generate(0, <<0::80>>)
      ulid_b = Ulid.generate(1, <<0::80>>)

      refute DeterministicNaming.runner_job_name(ulid_a, "build") ==
               DeterministicNaming.runner_job_name(ulid_b, "build")
    end
  end

  describe "pod_name/2" do
    test "follows the pattern run-<ulid>-j-<slugged jobKey>" do
      ulid = Ulid.generate(0, <<0::80>>)

      assert DeterministicNaming.pod_name(ulid, "build") ==
               "run-" <> ulid <> "-j-build"
    end

    test "matches runner_job_name/2 for the same inputs" do
      ulid = Ulid.generate()
      job_key = "deploy/m-abc123"

      assert DeterministicNaming.pod_name(ulid, job_key) ==
               DeterministicNaming.runner_job_name(ulid, job_key)
    end

    test "is pure and deterministic: identical inputs always yield an identical output" do
      ulid = Ulid.generate()
      job_key = "build"

      results = for _ <- 1..25, do: DeterministicNaming.pod_name(ulid, job_key)

      assert Enum.uniq(results) == [List.first(results)]
    end
  end
end
