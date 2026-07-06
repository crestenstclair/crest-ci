defmodule CrestCiGateway.Results.RestoreKeyResolverTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.{CacheEntry, CacheScope, RestoreKeyResolver}

  defp scope!(ref, repo) do
    {:ok, scope} = CacheScope.new(ref, repo)
    scope
  end

  defp entry!(key, scope, opts \\ []) do
    {:ok, entry} =
      CacheEntry.new(
        key,
        CacheScope.digest(scope),
        Keyword.get(opts, :size_bytes, 100),
        Keyword.get(opts, :state, :committed),
        Keyword.get(opts, :version, "v1"),
        Keyword.get(opts, :created_at, "2024-01-01T00:00:00Z"),
        Keyword.get(opts, :last_used_at, "2024-01-01T00:00:00Z")
      )

    entry
  end

  describe "exact key match" do
    test "an exact match wins immediately, even with restore_keys present" do
      branch = scope!("feature/x", "acme/repo")
      exact = entry!("deps-otp27-a1b2c3", branch, created_at: "2024-01-01T00:00:00Z")
      prefix_only = entry!("deps-otp27-zzzzzz", branch, created_at: "2024-06-01T00:00:00Z")

      assert {:ok, ^exact} =
               RestoreKeyResolver.resolve(
                 "deps-otp27-a1b2c3",
                 ["deps-otp27-", "deps-"],
                 [branch],
                 [exact, prefix_only]
               )
    end

    test "nearest scope wins over a farther scope with the same exact key" do
      branch = scope!("feature/x", "acme/repo")
      default = scope!("main", "acme/repo")

      near = entry!("deps-key", branch, version: "near")
      far = entry!("deps-key", default, version: "far")

      assert {:ok, ^near} =
               RestoreKeyResolver.resolve("deps-key", [], [branch, default], [far, near])
    end

    test "a reserved entry is never returned even on an exact key match" do
      branch = scope!("feature/x", "acme/repo")
      reserved = entry!("deps-key", branch, state: :reserved)

      assert :miss = RestoreKeyResolver.resolve("deps-key", [], [branch], [reserved])
    end

    test "an entry outside the scope chain is invisible" do
      branch = scope!("feature/x", "acme/repo")
      other_repo = scope!("feature/x", "other/repo")

      invisible = entry!("deps-key", other_repo)

      assert :miss = RestoreKeyResolver.resolve("deps-key", [], [branch], [invisible])
    end

    test "key comparison is case-sensitive" do
      branch = scope!("feature/x", "acme/repo")
      entry = entry!("Deps-Key", branch)

      assert :miss = RestoreKeyResolver.resolve("deps-key", [], [branch], [entry])
    end
  end

  describe "restore-key prefix fallback" do
    test "falls back to a prefix match when the exact key misses" do
      branch = scope!("feature/x", "acme/repo")
      hit = entry!("deps-otp27-a1b2c3", branch)

      assert {:ok, ^hit} =
               RestoreKeyResolver.resolve(
                 "deps-otp27-does-not-exist",
                 ["deps-otp27-"],
                 [branch],
                 [hit]
               )
    end

    test "the longest matching restore-key prefix wins regardless of list order" do
      branch = scope!("feature/x", "acme/repo")
      specific = entry!("deps-otp27-a1b2c3", branch, version: "specific")
      general = entry!("deps-otp26-x9y8z7", branch, version: "general")

      # restore_keys deliberately listed shortest-first: the resolver
      # must still prefer the longer "deps-otp27-" match over "deps-",
      # which also matches `specific`.
      assert {:ok, ^specific} =
               RestoreKeyResolver.resolve(
                 "deps-otp27-missing",
                 ["deps-", "deps-otp27-"],
                 [branch],
                 [specific, general]
               )
    end

    test "ties on prefix length are broken by nearest scope" do
      branch = scope!("feature/x", "acme/repo")
      default = scope!("main", "acme/repo")

      near = entry!("deps-near", branch, version: "near")
      far = entry!("deps-far", default, version: "far")

      assert {:ok, ^near} =
               RestoreKeyResolver.resolve(
                 "deps-missing",
                 ["deps-"],
                 [branch, default],
                 [far, near]
               )
    end

    test "ties on prefix length and scope are broken by most recently created" do
      branch = scope!("feature/x", "acme/repo")

      older = entry!("deps-a", branch, version: "older", created_at: "2024-01-01T00:00:00Z")
      newer = entry!("deps-b", branch, version: "newer", created_at: "2024-06-01T00:00:00Z")

      assert {:ok, ^newer} =
               RestoreKeyResolver.resolve(
                 "deps-missing",
                 ["deps-"],
                 [branch],
                 [older, newer]
               )
    end

    test "reserved entries are never candidates for restore-key fallback" do
      branch = scope!("feature/x", "acme/repo")
      reserved = entry!("deps-a", branch, state: :reserved)

      assert :miss =
               RestoreKeyResolver.resolve("deps-missing", ["deps-"], [branch], [reserved])
    end

    test "entries outside the scope chain never match via restore key either" do
      branch = scope!("feature/x", "acme/repo")
      other_repo = scope!("feature/x", "other/repo")
      invisible = entry!("deps-a", other_repo)

      assert :miss =
               RestoreKeyResolver.resolve("deps-missing", ["deps-"], [branch], [invisible])
    end

    test "blank restore keys are ignored rather than matching everything" do
      branch = scope!("feature/x", "acme/repo")
      entry = entry!("deps-a", branch)

      assert :miss =
               RestoreKeyResolver.resolve("deps-missing", [""], [branch], [entry])
    end
  end

  describe "no match" do
    test "returns :miss when nothing matches exactly or by prefix" do
      branch = scope!("feature/x", "acme/repo")
      entry = entry!("unrelated-key", branch)

      assert :miss = RestoreKeyResolver.resolve("deps-missing", ["deps-"], [branch], [entry])
    end

    test "returns :miss with no restore_keys and no entries" do
      branch = scope!("feature/x", "acme/repo")

      assert :miss = RestoreKeyResolver.resolve("deps-missing", [], [branch], [])
    end
  end
end
