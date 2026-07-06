defmodule CrestCiContract.LabelSchemaTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.{JobKey, LabelSchema, Ulid}

  describe "build_labels/4" do
    test "emits exactly the four crest.dev/* keys" do
      labels = LabelSchema.build_labels(Ulid.generate(), "build", ["ubuntu-latest"], "default")

      assert Map.keys(labels) |> Enum.sort() == Enum.sort(LabelSchema.label_keys())
    end

    test "every key is crest.dev/*-prefixed" do
      labels = LabelSchema.build_labels(Ulid.generate(), "test/m-3f9a2c", ["self-hosted"], "east")

      assert Enum.all?(Map.keys(labels), &String.starts_with?(&1, "crest.dev/"))
    end

    test "stores the run ulid verbatim" do
      ulid = Ulid.generate()
      labels = LabelSchema.build_labels(ulid, "build", ["ubuntu-latest"], "default")

      assert labels["crest.dev/run-ulid"] == ulid
    end

    test "stores the job key as its slug, not the raw job key" do
      labels = LabelSchema.build_labels(Ulid.generate(), "test/m-3f9a2c", [], "default")

      assert labels["crest.dev/job-key"] == JobKey.slug("test/m-3f9a2c")
      assert labels["crest.dev/job-key"] == "test-m-3f9a2c"
    end

    test "stores the cluster verbatim" do
      labels = LabelSchema.build_labels(Ulid.generate(), "build", ["ubuntu-latest"], "prod-east")

      assert labels["crest.dev/cluster"] == "prod-east"
    end

    test "stores a runs-on hash matching runs_on_hash/1" do
      runs_on = ["ubuntu-latest", "self-hosted"]
      labels = LabelSchema.build_labels(Ulid.generate(), "build", runs_on, "default")

      assert labels["crest.dev/runs-on-hash"] == LabelSchema.runs_on_hash(runs_on)
    end

    test "is pure and deterministic across repeated invocations" do
      ulid = Ulid.generate()

      first = LabelSchema.build_labels(ulid, "build", ["ubuntu-latest"], "default")
      second = LabelSchema.build_labels(ulid, "build", ["ubuntu-latest"], "default")

      assert first == second
    end
  end

  describe "runs_on_hash/1" do
    test "is deterministic for the same list" do
      runs_on = ["ubuntu-latest", "self-hosted"]

      assert LabelSchema.runs_on_hash(runs_on) == LabelSchema.runs_on_hash(runs_on)
    end

    test "is order-independent (same set, different order hashes identically)" do
      assert LabelSchema.runs_on_hash(["a", "b", "c"]) ==
               LabelSchema.runs_on_hash(["c", "a", "b"])
    end

    test "different runs-on sets hash differently" do
      refute LabelSchema.runs_on_hash(["ubuntu-latest"]) ==
               LabelSchema.runs_on_hash(["self-hosted"])
    end

    test "produces a non-empty label-safe value" do
      hash = LabelSchema.runs_on_hash(["ubuntu-latest"])

      assert byte_size(hash) > 0
      assert byte_size(hash) <= 63

      assert hash
             |> String.to_charlist()
             |> Enum.all?(fn c ->
               (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9)
             end)
    end
  end

  describe "parse_labels/1" do
    test "round-trips build_labels/4 output for run_ulid and cluster verbatim" do
      ulid = Ulid.generate()
      labels = LabelSchema.build_labels(ulid, "build", ["ubuntu-latest"], "default")

      assert {:ok, parsed} = LabelSchema.parse_labels(labels)
      assert parsed.run_ulid == ulid
      assert parsed.cluster == "default"
    end

    test "round-trips the job key as its slug" do
      job_key = "test/m-3f9a2c"
      labels = LabelSchema.build_labels(Ulid.generate(), job_key, ["ubuntu-latest"], "default")

      assert {:ok, parsed} = LabelSchema.parse_labels(labels)
      assert parsed.job_key == JobKey.slug(job_key)
    end

    test "round-trips the runs-on hash so it matches an independently computed hash" do
      runs_on = ["ubuntu-latest", "self-hosted"]
      labels = LabelSchema.build_labels(Ulid.generate(), "build", runs_on, "default")

      assert {:ok, parsed} = LabelSchema.parse_labels(labels)
      assert parsed.runs_on_hash == LabelSchema.runs_on_hash(runs_on)
    end

    test "full round trip: build then parse reproduces every field losslessly" do
      ulid = Ulid.generate()
      job_key = "deploy/m-abc123"
      runs_on = ["self-hosted", "gpu"]
      cluster = "west-2"

      labels = LabelSchema.build_labels(ulid, job_key, runs_on, cluster)

      assert {:ok, parsed} = LabelSchema.parse_labels(labels)

      assert parsed == %{
               run_ulid: ulid,
               job_key: JobKey.slug(job_key),
               runs_on_hash: LabelSchema.runs_on_hash(runs_on),
               cluster: cluster
             }
    end

    test "ignores unrelated extra keys on the input map" do
      labels =
        Ulid.generate()
        |> LabelSchema.build_labels("build", ["ubuntu-latest"], "default")
        |> Map.put("some.other/label", "irrelevant")

      assert {:ok, _parsed} = LabelSchema.parse_labels(labels)
    end

    test "returns {:error, :missing_labels} when a required label is absent" do
      labels = LabelSchema.build_labels(Ulid.generate(), "build", ["ubuntu-latest"], "default")

      incomplete = Map.delete(labels, "crest.dev/cluster")

      assert {:error, :missing_labels} = LabelSchema.parse_labels(incomplete)
    end

    test "returns {:error, :missing_labels} for an empty map" do
      assert {:error, :missing_labels} = LabelSchema.parse_labels(%{})
    end
  end
end
