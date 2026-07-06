defmodule CrestCiGateway.Results.CacheScopeTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.CacheScope

  describe "new/2" do
    test "builds a scope from non-empty ref and repo" do
      assert {:ok, %CacheScope{ref: "refs/heads/feature-x", repo: "acme/widgets"}} =
               CacheScope.new("refs/heads/feature-x", "acme/widgets")
    end

    test "rejects an empty ref" do
      assert {:error, :invalid_cache_scope} = CacheScope.new("", "acme/widgets")
    end

    test "rejects an empty repo" do
      assert {:error, :invalid_cache_scope} = CacheScope.new("refs/heads/main", "")
    end

    test "rejects non-binary fields" do
      assert {:error, :invalid_cache_scope} = CacheScope.new(nil, "acme/widgets")
      assert {:error, :invalid_cache_scope} = CacheScope.new("refs/heads/main", nil)
      assert {:error, :invalid_cache_scope} = CacheScope.new(123, "acme/widgets")
    end
  end

  describe "lookup_chain/2" do
    test "walks the branch ref first, then the default ref, when they differ" do
      {:ok, scope} = CacheScope.new("refs/heads/feature-x", "acme/widgets")

      assert {:ok,
              [
                %CacheScope{ref: "refs/heads/feature-x", repo: "acme/widgets"},
                %CacheScope{ref: "refs/heads/main", repo: "acme/widgets"}
              ]} = CacheScope.lookup_chain(scope, "refs/heads/main")
    end

    test "dedupes to a single-element chain when ref already is the default ref" do
      {:ok, scope} = CacheScope.new("refs/heads/main", "acme/widgets")

      assert {:ok, [%CacheScope{ref: "refs/heads/main", repo: "acme/widgets"}]} =
               CacheScope.lookup_chain(scope, "refs/heads/main")
    end

    test "preserves the original scope's repo in the fallback element" do
      {:ok, scope} = CacheScope.new("refs/heads/feature-x", "acme/widgets")
      {:ok, [_first, fallback]} = CacheScope.lookup_chain(scope, "refs/heads/main")

      assert fallback.repo == "acme/widgets"
    end

    test "rejects a non-binary or empty default_ref" do
      {:ok, scope} = CacheScope.new("refs/heads/feature-x", "acme/widgets")

      assert {:error, :invalid_cache_scope} = CacheScope.lookup_chain(scope, "")
      assert {:error, :invalid_cache_scope} = CacheScope.lookup_chain(scope, nil)
    end
  end

  describe "digest/1" do
    test "is deterministic for identical scopes" do
      {:ok, a} = CacheScope.new("refs/heads/main", "acme/widgets")
      {:ok, b} = CacheScope.new("refs/heads/main", "acme/widgets")

      assert CacheScope.digest(a) == CacheScope.digest(b)
    end

    test "differs when repo differs" do
      {:ok, a} = CacheScope.new("refs/heads/main", "acme/widgets")
      {:ok, b} = CacheScope.new("refs/heads/main", "acme/gadgets")

      assert CacheScope.digest(a) != CacheScope.digest(b)
    end

    test "differs when ref differs" do
      {:ok, a} = CacheScope.new("refs/heads/main", "acme/widgets")
      {:ok, b} = CacheScope.new("refs/heads/feature-x", "acme/widgets")

      assert CacheScope.digest(a) != CacheScope.digest(b)
    end

    test "does not collide across a repo/ref byte-boundary shift" do
      {:ok, a} = CacheScope.new("bc", "a")
      {:ok, b} = CacheScope.new("c", "ab")

      assert CacheScope.digest(a) != CacheScope.digest(b)
    end

    test "produces a lowercase hex-encoded sha256 (64 chars)" do
      {:ok, scope} = CacheScope.new("refs/heads/main", "acme/widgets")
      digest = CacheScope.digest(scope)

      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "to_wire/1 and from_wire/1" do
    test "round-trips through the wire format" do
      {:ok, scope} = CacheScope.new("refs/heads/feature-x", "acme/widgets")

      assert {:ok, ^scope} = scope |> CacheScope.to_wire() |> CacheScope.from_wire()
    end

    test "to_wire uses camelCase-compatible string keys" do
      {:ok, scope} = CacheScope.new("refs/heads/main", "acme/widgets")

      assert CacheScope.to_wire(scope) == %{"ref" => "refs/heads/main", "repo" => "acme/widgets"}
    end

    test "from_wire rejects a map missing a required field" do
      assert {:error, :invalid_cache_scope} = CacheScope.from_wire(%{"ref" => "refs/heads/main"})
      assert {:error, :invalid_cache_scope} = CacheScope.from_wire(%{"repo" => "acme/widgets"})
    end

    test "from_wire rejects wrongly-typed fields" do
      assert {:error, :invalid_cache_scope} =
               CacheScope.from_wire(%{"ref" => 1, "repo" => "acme/widgets"})

      assert {:error, :invalid_cache_scope} =
               CacheScope.from_wire(%{"ref" => "refs/heads/main", "repo" => nil})
    end

    test "from_wire rejects a non-map" do
      assert {:error, :invalid_cache_scope} = CacheScope.from_wire("not a map")
    end
  end
end
