defmodule CrestCiController.Engine.ExprValueTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.ExprValue

  doctest ExprValue

  describe "valid?/1" do
    test "accepts every branch of the closed shape" do
      assert ExprValue.valid?(nil)
      assert ExprValue.valid?(true)
      assert ExprValue.valid?(false)
      assert ExprValue.valid?(0)
      assert ExprValue.valid?(-3.5)
      assert ExprValue.valid?("")
      assert ExprValue.valid?("hello")
    end

    test "rejects terms outside the closed shape" do
      refute ExprValue.valid?(%{})
      refute ExprValue.valid?([])
      refute ExprValue.valid?([1, 2, 3])
      refute ExprValue.valid?(%{"a" => 1})
      refute ExprValue.valid?(:atom)
      refute ExprValue.valid?({:tuple, 1})
    end
  end

  describe "type_of/1" do
    test "names each branch" do
      assert ExprValue.type_of(nil) == :null
      assert ExprValue.type_of(true) == :bool
      assert ExprValue.type_of(false) == :bool
      assert ExprValue.type_of(1) == :number
      assert ExprValue.type_of(1.5) == :number
      assert ExprValue.type_of("s") == :string
    end

    test "reports non-members as an error rather than raising" do
      assert ExprValue.type_of(%{}) == {:error, :not_expr_value}
      assert ExprValue.type_of([1]) == {:error, :not_expr_value}
    end
  end

  describe "truthy?/1" do
    test "nil and false are falsy" do
      refute ExprValue.truthy?(nil)
      refute ExprValue.truthy?(false)
    end

    test "true is truthy" do
      assert ExprValue.truthy?(true)
    end

    test "zero (integer and float) is falsy" do
      refute ExprValue.truthy?(0)
      refute ExprValue.truthy?(0.0)
    end

    test "any non-zero number is truthy" do
      assert ExprValue.truthy?(1)
      assert ExprValue.truthy?(-1)
      assert ExprValue.truthy?(0.1)
    end

    test "empty string is falsy" do
      refute ExprValue.truthy?("")
    end

    test "any non-empty string is truthy, including \"false\" and \"0\"" do
      assert ExprValue.truthy?("false")
      assert ExprValue.truthy?("0")
      assert ExprValue.truthy?("hello")
    end
  end

  describe "loose_equal?/2 — string comparison is case-insensitive" do
    test "identical case matches" do
      assert ExprValue.loose_equal?("abc", "abc")
    end

    test "differing case still matches" do
      assert ExprValue.loose_equal?("ABC", "abc")
      assert ExprValue.loose_equal?("Yes", "yES")
    end

    test "different strings never match" do
      refute ExprValue.loose_equal?("abc", "xyz")
    end
  end

  describe "loose_equal?/2 — numeric coercion for non-string pairs" do
    test "true coerces to 1" do
      assert ExprValue.loose_equal?(true, 1)
      assert ExprValue.loose_equal?(1, true)
    end

    test "false coerces to 0" do
      assert ExprValue.loose_equal?(false, 0)
    end

    test "nil coerces to 0" do
      assert ExprValue.loose_equal?(nil, 0)
      assert ExprValue.loose_equal?(nil, false)
    end

    test "identical numbers match regardless of int/float representation" do
      assert ExprValue.loose_equal?(1, 1.0)
    end

    test "different numbers never match" do
      refute ExprValue.loose_equal?(1, 2)
    end

    test "a non-numeric string never equals a non-string, even nil" do
      refute ExprValue.loose_equal?("abc", nil)
      refute ExprValue.loose_equal?("abc", 0)
      refute ExprValue.loose_equal?("abc", false)
    end

    test "a numeric string coerces for comparison against a number" do
      assert ExprValue.loose_equal?("3", 3)
      assert ExprValue.loose_equal?("3.5", 3.5)
    end
  end

  describe "to_number/1" do
    test "coerces nil, true, false" do
      assert ExprValue.to_number(nil) == 0
      assert ExprValue.to_number(true) == 1
      assert ExprValue.to_number(false) == 0
    end

    test "passes numbers through unchanged" do
      assert ExprValue.to_number(42) == 42
      assert ExprValue.to_number(3.5) == 3.5
    end

    test "parses numeric strings" do
      assert ExprValue.to_number("3") == 3
      assert ExprValue.to_number("3.5") == 3.5
      assert ExprValue.to_number("") == 0
    end

    test "returns :nan for non-numeric strings, and :nan never equals itself" do
      assert ExprValue.to_number("not a number") == :nan
      refute ExprValue.loose_equal?("not a number", "0")
    end
  end
end
