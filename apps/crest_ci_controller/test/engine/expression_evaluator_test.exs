defmodule CrestCiController.Engine.ExpressionEvaluatorTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.ExpressionEvaluator

  describe "literals" do
    test "null, true, false" do
      assert ExpressionEvaluator.evaluate("null", %{}) == {:ok, nil}
      assert ExpressionEvaluator.evaluate("true", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("false", %{}) == {:ok, false}
    end

    test "numbers: decimal, negative, exponent, hex" do
      assert ExpressionEvaluator.evaluate("42", %{}) == {:ok, 42}
      assert ExpressionEvaluator.evaluate("-3.5", %{}) == {:ok, -3.5}
      assert ExpressionEvaluator.evaluate("1e2", %{}) == {:ok, 100.0}
      assert ExpressionEvaluator.evaluate("0x1F", %{}) == {:ok, 31}
    end

    test "single-quoted strings with '' escape" do
      assert ExpressionEvaluator.evaluate("'hello'", %{}) == {:ok, "hello"}
      assert ExpressionEvaluator.evaluate("'it''s'", %{}) == {:ok, "it's"}
    end

    test "strips a ${{ }} wrapper" do
      assert ExpressionEvaluator.evaluate("${{ true }}", %{}) == {:ok, true}
    end
  end

  describe "operators" do
    test "equality is loose and coercive" do
      assert ExpressionEvaluator.evaluate("null == ''", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("'1' == 1", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("true == 1", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("false == 0", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("1 != 2", %{}) == {:ok, true}
    end

    test "string equality is case-insensitive" do
      assert ExpressionEvaluator.evaluate("'Hello' == 'hello'", %{}) == {:ok, true}
    end

    test "comparison operators coerce numerically" do
      assert ExpressionEvaluator.evaluate("1 < 2", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("2 <= 2", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("3 > 2", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("'2' >= 2", %{}) == {:ok, true}
    end

    test "a non-numeric operand never compares equal or ordered under numeric coercion" do
      assert ExpressionEvaluator.evaluate("fromJSON('[1]') == 1", %{}) == {:ok, false}
      assert ExpressionEvaluator.evaluate("1 < 'nope'", %{}) == {:ok, false}
    end

    test "&& and || short-circuit and return the operand, not a coerced boolean" do
      assert ExpressionEvaluator.evaluate("'' && 'unused'", %{}) == {:ok, ""}
      assert ExpressionEvaluator.evaluate("'left' || 'right'", %{}) == {:ok, "left"}
      assert ExpressionEvaluator.evaluate("null || 'fallback'", %{}) == {:ok, "fallback"}
    end

    test "! coerces to boolean" do
      assert ExpressionEvaluator.evaluate("!null", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("!'nonempty'", %{}) == {:ok, false}
    end
  end

  describe "context access" do
    test "property access via dot and bracket" do
      ctx = %{"github" => %{"event_name" => "push", "ref" => "refs/heads/main"}}
      assert ExpressionEvaluator.evaluate("github.event_name", ctx) == {:ok, "push"}
      assert ExpressionEvaluator.evaluate("github['ref']", ctx) == {:ok, "refs/heads/main"}
    end

    test "array indexing" do
      ctx = %{"matrix" => ["a", "b", "c"]}
      assert ExpressionEvaluator.evaluate("matrix[1]", ctx) == {:ok, "b"}
    end

    test "missing property, out-of-range index, and indexing a scalar all resolve to null" do
      ctx = %{"github" => %{"ref" => "refs/heads/main"}}
      assert ExpressionEvaluator.evaluate("github.nope", ctx) == {:ok, nil}
      assert ExpressionEvaluator.evaluate("github.ref[9]", ctx) == {:ok, nil}
      assert ExpressionEvaluator.evaluate("nonexistent.deep.path", ctx) == {:ok, nil}
    end

    test "property lookup is case-insensitive as a fallback" do
      ctx = %{"github" => %{"Event_Name" => "push"}}
      assert ExpressionEvaluator.evaluate("github.event_name", ctx) == {:ok, "push"}
    end
  end

  describe "functions" do
    test "contains on strings and arrays" do
      assert ExpressionEvaluator.evaluate("contains('Hello World', 'world')", %{}) == {:ok, true}

      assert ExpressionEvaluator.evaluate("contains(fromJSON('[\"a\",\"b\"]'), 'b')", %{}) ==
               {:ok, true}

      assert ExpressionEvaluator.evaluate("contains(fromJSON('[\"a\",\"b\"]'), 'z')", %{}) ==
               {:ok, false}
    end

    test "startsWith and endsWith are case-insensitive" do
      assert ExpressionEvaluator.evaluate("startsWith('HELLO', 'he')", %{}) == {:ok, true}
      assert ExpressionEvaluator.evaluate("endsWith('HELLO', 'LO')", %{}) == {:ok, true}
    end

    test "format substitutes positional args and honors {{ }} escapes" do
      assert ExpressionEvaluator.evaluate("format('{0} of {1}', 3, 10)", %{}) == {:ok, "3 of 10"}

      assert ExpressionEvaluator.evaluate("format('literal {{0}} brace')", %{}) ==
               {:ok, "literal {0} brace"}
    end

    test "join with default and custom separators" do
      ctx = %{"items" => ["a", "b", "c"]}
      assert ExpressionEvaluator.evaluate("join(items)", ctx) == {:ok, "a,b,c"}
      assert ExpressionEvaluator.evaluate("join(items, ' - ')", ctx) == {:ok, "a - b - c"}
    end

    test "toJSON and fromJSON round-trip" do
      ctx = %{"obj" => %{"a" => 1}}
      assert {:ok, json} = ExpressionEvaluator.evaluate("toJSON(obj)", ctx)
      assert {:ok, decoded} = ExpressionEvaluator.evaluate("fromJSON('#{json}')", %{})
      assert decoded == %{"a" => 1}
    end

    test "always is unconditionally true" do
      assert ExpressionEvaluator.evaluate("always()", %{}) == {:ok, true}
    end

    test "success/failure/cancelled read the needs context" do
      all_success = %{"needs" => %{"build" => %{"result" => "success"}}}
      assert ExpressionEvaluator.evaluate("success()", all_success) == {:ok, true}
      assert ExpressionEvaluator.evaluate("failure()", all_success) == {:ok, false}
      assert ExpressionEvaluator.evaluate("cancelled()", all_success) == {:ok, false}

      one_failed = %{
        "needs" => %{
          "build" => %{"result" => "success"},
          "test" => %{"result" => "failure"}
        }
      }

      assert ExpressionEvaluator.evaluate("success()", one_failed) == {:ok, false}
      assert ExpressionEvaluator.evaluate("failure()", one_failed) == {:ok, true}

      assert ExpressionEvaluator.evaluate("success()", %{}) == {:ok, true}
    end
  end

  describe "errors" do
    test "malformed syntax is a parse_error" do
      assert {:error, {:parse_error, _}} = ExpressionEvaluator.evaluate("1 +", %{})
      assert {:error, {:parse_error, _}} = ExpressionEvaluator.evaluate("(1", %{})
    end

    test "unknown function is an eval_error" do
      assert {:error, {:eval_error, _}} = ExpressionEvaluator.evaluate("nope()", %{})
    end

    test "wrong arity is an eval_error" do
      assert {:error, {:eval_error, _}} = ExpressionEvaluator.evaluate("contains('a')", %{})
    end
  end
end
