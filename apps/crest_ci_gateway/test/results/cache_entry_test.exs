defmodule CrestCiGateway.Results.CacheEntryTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheEntry

  describe "new/7" do
    test "builds a valid reserved CacheEntry from well-shaped values" do
      assert {:ok, %CacheEntry{} = entry} =
               CacheEntry.new(
                 "deps-lock-abc123",
                 "repo:acme/widgets",
                 0,
                 :reserved,
                 "v1",
                 "2026-01-01T00:00:00Z",
                 "2026-01-01T00:00:00Z"
               )

      assert entry.key == "deps-lock-abc123"
      assert entry.scope == "repo:acme/widgets"
      assert entry.size_bytes == 0
      assert entry.state == :reserved
      assert entry.version == "v1"
      assert entry.created_at == "2026-01-01T00:00:00Z"
      assert entry.last_used_at == "2026-01-01T00:00:00Z"
    end

    test "builds a valid committed CacheEntry" do
      assert {:ok, %CacheEntry{state: :committed}} =
               CacheEntry.new(
                 "key",
                 "scope",
                 1024,
                 :committed,
                 "v2",
                 "2026-01-01T00:00:00Z",
                 "2026-01-02T00:00:00Z"
               )
    end

    test "rejects an empty key" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("", "scope", 0, :reserved, "v1", "t", "t")
    end

    test "rejects a non-binary key" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new(nil, "scope", 0, :reserved, "v1", "t", "t")
    end

    test "rejects an empty scope" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "", 0, :reserved, "v1", "t", "t")
    end

    test "rejects a negative size_bytes" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", -1, :reserved, "v1", "t", "t")
    end

    test "rejects a non-integer size_bytes" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", "0", :reserved, "v1", "t", "t")
    end

    test "rejects an invalid state atom" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", 0, :abandoned, "v1", "t", "t")
    end

    test "rejects an empty version" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", 0, :reserved, "", "t", "t")
    end

    test "rejects an empty created_at" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", 0, :reserved, "v1", "", "t")
    end

    test "rejects an empty last_used_at" do
      assert {:error, :invalid_cache_entry} =
               CacheEntry.new("key", "scope", 0, :reserved, "v1", "t", "")
    end
  end

  describe "identity/1" do
    test "returns the (scope, key) lookup identity" do
      {:ok, entry} =
        CacheEntry.new("deps-lock", "repo:acme/widgets", 0, :reserved, "v1", "t", "t")

      assert CacheEntry.identity(entry) == {"repo:acme/widgets", "deps-lock"}
    end

    test "two entries with the same (scope, key) but different version share identity" do
      {:ok, first} = CacheEntry.new("key", "scope", 0, :reserved, "v1", "t", "t")
      {:ok, second} = CacheEntry.new("key", "scope", 100, :committed, "v2", "t", "t2")

      assert CacheEntry.identity(first) == CacheEntry.identity(second)
    end

    test "differing scope yields differing identity" do
      {:ok, a} = CacheEntry.new("key", "scope-a", 0, :reserved, "v1", "t", "t")
      {:ok, b} = CacheEntry.new("key", "scope-b", 0, :reserved, "v1", "t", "t")

      refute CacheEntry.identity(a) == CacheEntry.identity(b)
    end
  end

  describe "servable?/1" do
    test "a committed entry is servable" do
      {:ok, entry} = CacheEntry.new("key", "scope", 0, :committed, "v1", "t", "t")
      assert CacheEntry.servable?(entry)
    end

    test "a reserved entry is not servable" do
      {:ok, entry} = CacheEntry.new("key", "scope", 0, :reserved, "v1", "t", "t")
      refute CacheEntry.servable?(entry)
    end
  end

  describe "commit/1" do
    test "transitions a reserved entry to committed" do
      {:ok, entry} = CacheEntry.new("key", "scope", 512, :reserved, "v1", "t", "t")

      assert {:ok, %CacheEntry{state: :committed} = committed} = CacheEntry.commit(entry)
      assert committed.key == entry.key
      assert committed.version == entry.version
    end

    test "rejects committing an already-committed entry" do
      {:ok, entry} = CacheEntry.new("key", "scope", 512, :committed, "v1", "t", "t")

      assert {:error, :not_reserved} = CacheEntry.commit(entry)
    end
  end

  describe "touch/2" do
    test "updates last_used_at and leaves other fields untouched" do
      {:ok, entry} = CacheEntry.new("key", "scope", 512, :committed, "v1", "t0", "t0")

      touched = CacheEntry.touch(entry, "t1")

      assert touched.last_used_at == "t1"
      assert touched.key == entry.key
      assert touched.scope == entry.scope
      assert touched.size_bytes == entry.size_bytes
      assert touched.state == entry.state
      assert touched.version == entry.version
      assert touched.created_at == entry.created_at
    end

    test "touching a reserved entry does not make it servable" do
      {:ok, entry} = CacheEntry.new("key", "scope", 0, :reserved, "v1", "t0", "t0")

      touched = CacheEntry.touch(entry, "t1")

      refute CacheEntry.servable?(touched)
    end
  end

  describe "to_wire/1 and from_wire/1 round-trip" do
    test "round-trips a reserved entry through the wire map" do
      {:ok, entry} =
        CacheEntry.new(
          "deps-lock-abc123",
          "repo:acme/widgets",
          0,
          :reserved,
          "v1",
          "2026-01-01T00:00:00Z",
          "2026-01-01T00:00:00Z"
        )

      wire = CacheEntry.to_wire(entry)

      assert wire == %{
               "key" => "deps-lock-abc123",
               "scope" => "repo:acme/widgets",
               "sizeBytes" => 0,
               "state" => "Reserved",
               "version" => "v1",
               "createdAt" => "2026-01-01T00:00:00Z",
               "lastUsedAt" => "2026-01-01T00:00:00Z"
             }

      assert {:ok, ^entry} = CacheEntry.from_wire(wire)
    end

    test "round-trips a committed entry through the wire map" do
      {:ok, entry} =
        CacheEntry.new("key", "scope", 2048, :committed, "v2", "t0", "t1")

      wire = CacheEntry.to_wire(entry)
      assert wire["state"] == "Committed"
      assert {:ok, ^entry} = CacheEntry.from_wire(wire)
    end

    test "from_wire rejects a map missing a required field" do
      wire = %{
        "key" => "k",
        "scope" => "s",
        "sizeBytes" => 0,
        "state" => "Reserved",
        "version" => "v1",
        "createdAt" => "t"
      }

      assert {:error, :invalid_cache_entry} = CacheEntry.from_wire(wire)
    end

    test "from_wire rejects a map with a wrongly-typed field" do
      wire = %{
        "key" => "k",
        "scope" => "s",
        "sizeBytes" => "0",
        "state" => "Reserved",
        "version" => "v1",
        "createdAt" => "t",
        "lastUsedAt" => "t"
      }

      assert {:error, :invalid_cache_entry} = CacheEntry.from_wire(wire)
    end

    test "from_wire rejects an unknown state string" do
      wire = %{
        "key" => "k",
        "scope" => "s",
        "sizeBytes" => 0,
        "state" => "Abandoned",
        "version" => "v1",
        "createdAt" => "t",
        "lastUsedAt" => "t"
      }

      assert {:error, :invalid_cache_entry} = CacheEntry.from_wire(wire)
    end

    test "from_wire rejects a non-map" do
      assert {:error, :invalid_cache_entry} = CacheEntry.from_wire("not a map")
    end
  end
end
