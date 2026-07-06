defmodule SimRunner.Demo.NamingTest do
  use ExUnit.Case, async: true

  alias SimRunner.Demo.Naming

  describe "run_name/1" do
    test "prefixes the run ulid" do
      assert Naming.run_name("01ARZ3NDEKTSV4RRFFQ69G5FAV") == "run-01ARZ3NDEKTSV4RRFFQ69G5FAV"
    end
  end

  describe "child_name/2" do
    test "derives a deterministic name from run ulid + job key" do
      assert Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "build") ==
               "run-01ARZ3NDEKTSV4RRFFQ69G5FAV-j-build"
    end

    test "slugs job keys containing slashes (matrix jobs)" do
      assert Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "test/m-3f9a2c") ==
               "run-01ARZ3NDEKTSV4RRFFQ69G5FAV-j-test-m-3f9a2c"
    end

    test "is pure and deterministic: identical input always yields identical output" do
      first = Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "test-a")
      second = Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "test-a")
      assert first == second
    end

    test "different job keys under the same run never collide" do
      build = Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "build")
      test_a = Naming.child_name("01ARZ3NDEKTSV4RRFFQ69G5FAV", "test-a")
      refute build == test_a
    end
  end
end
