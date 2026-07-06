defmodule CrestCiContract.UlidTest do
  use ExUnit.Case, async: true

  alias CrestCiContract.Ulid

  describe "generate/0" do
    test "produces a 26-character string" do
      assert String.length(Ulid.generate()) == 26
    end

    test "produces only Crockford base32 characters" do
      ulid = Ulid.generate()

      assert ulid
             |> String.to_charlist()
             |> Enum.all?(fn c ->
               (c >= ?0 and c <= ?9) or (c >= ?A and c <= ?Z)
             end)

      refute String.contains?(ulid, "I")
      refute String.contains?(ulid, "L")
      refute String.contains?(ulid, "O")
      refute String.contains?(ulid, "U")
    end

    test "produces distinct values across repeated calls" do
      ulids = for _ <- 1..50, do: Ulid.generate()
      assert Enum.uniq(ulids) |> length() == 50
    end
  end

  describe "generate/2 (explicit timestamp + randomness)" do
    test "is deterministic for identical inputs" do
      random = :crypto.strong_rand_bytes(10)
      assert Ulid.generate(1_000, random) == Ulid.generate(1_000, random)
    end

    test "produces exactly 26 Crockford base32 characters" do
      ulid = Ulid.generate(1_720_000_000_000, :crypto.strong_rand_bytes(10))
      assert Ulid.valid?(ulid)
    end

    test "later timestamps sort lexicographically after earlier ones" do
      random = :crypto.strong_rand_bytes(10)

      earlier = Ulid.generate(1_000, random)
      later = Ulid.generate(2_000, random)

      assert earlier < later
    end

    test "monotonic ordering holds across many increasing timestamps" do
      base = 1_700_000_000_000

      ulids =
        for offset <- 0..99 do
          Ulid.generate(base + offset, :crypto.strong_rand_bytes(10))
        end

      assert ulids == Enum.sort(ulids)
    end

    test "differing randomness at the same millisecond does not violate ordering across millis" do
      earlier = Ulid.generate(500, :crypto.strong_rand_bytes(10))
      later = Ulid.generate(501, :crypto.strong_rand_bytes(10))

      assert earlier < later
    end
  end

  describe "valid?/1" do
    test "accepts a generated ULID" do
      assert Ulid.valid?(Ulid.generate())
    end

    test "rejects wrong length" do
      refute Ulid.valid?("TOOSHORT")
      refute Ulid.valid?(String.duplicate("0", 27))
    end

    test "rejects characters outside the Crockford alphabet" do
      refute Ulid.valid?(String.duplicate("I", 26))
      refute Ulid.valid?(String.duplicate("l", 26))
      refute Ulid.valid?(String.duplicate("0", 25) <> "!")
    end

    test "rejects non-binary input" do
      refute Ulid.valid?(nil)
      refute Ulid.valid?(123)
    end
  end
end
