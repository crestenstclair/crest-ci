defmodule CrestCiGateway.Results.CacheKeyTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheKey

  doctest CrestCiGateway.Results.CacheKey

  describe "new/1" do
    test "accepts a simple cache key" do
      assert {:ok, %CacheKey{value: "deps-otp27-a1b2c3"}} =
               CacheKey.new("deps-otp27-a1b2c3")
    end

    test "accepts an all-whitespace string (no trimming performed)" do
      assert {:ok, %CacheKey{value: "   "}} = CacheKey.new("   ")
    end

    test "rejects an empty string" do
      assert {:error, :blank} = CacheKey.new("")
    end

    test "rejects non-string input" do
      assert {:error, :not_a_string} = CacheKey.new(123)
    end
  end

  describe "new!/1" do
    test "returns the struct directly for valid input" do
      assert %CacheKey{value: "ok-key"} = CacheKey.new!("ok-key")
    end

    test "raises for invalid input" do
      assert_raise ArgumentError, fn -> CacheKey.new!("") end
    end
  end

  describe "to_string/1" do
    test "returns the underlying string" do
      {:ok, cache_key} = CacheKey.new("deps-key")
      assert CacheKey.to_string(cache_key) == "deps-key"
    end
  end

  describe "equal?/2" do
    test "is true for identical keys" do
      {:ok, a} = CacheKey.new("deps-key")
      {:ok, b} = CacheKey.new("deps-key")
      assert CacheKey.equal?(a, b)
    end

    test "is case-sensitive: differing case means different keys" do
      {:ok, a} = CacheKey.new("Deps-Key")
      {:ok, b} = CacheKey.new("deps-key")
      refute CacheKey.equal?(a, b)
    end

    test "is false for entirely different keys" do
      {:ok, a} = CacheKey.new("deps-key")
      {:ok, b} = CacheKey.new("build-key")
      refute CacheKey.equal?(a, b)
    end
  end
end
