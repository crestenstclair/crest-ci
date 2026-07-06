defmodule CrestCiController.Engine.ExpressionConformanceTest do
  @moduledoc """
  Table-driven conformance suite for `CrestCiController.Engine.ExpressionEvaluator`:
  every vector is an `{expression, context, expected}` tuple, `expected`
  being the exact plain Elixir term (`nil | boolean | number |
  String.t() | list() | map()`) `evaluate/2` must return for that
  `(expression, context)` pair.

  Covers: every literal kind (`null`, booleans, integers, floats, `0x`
  hex, exponent notation, single-quoted strings with the `''` escape);
  every operator (`==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, unary
  `!`); dotted property access and bracketed index access, including
  the "missing path resolves to `null`, never raises" invariant at
  every depth; every built-in function (`contains` on both strings and
  arrays, `startsWith`, `endsWith`, `format` with escaped `{{ }}`
  braces, `join` with a custom separator, `toJSON`/`fromJSON`);
  GitHub's documented coercion edge cases (`null == ''`, `'1' == 1`,
  `true == 1`, and case-insensitive string comparison); and
  `always()`/`success()`/`failure()`/`cancelled()` against a job-status
  (`needs`) context.
  """

  use ExUnit.Case, async: true

  alias CrestCiController.Engine.ExpressionEvaluator

  # Each vector: {expression, context, expected plain term}.
  @vectors [
    # -- literals ------------------------------------------------------
    {"null", %{}, nil},
    {"true", %{}, true},
    {"false", %{}, false},
    {"1", %{}, 1},
    {"1.5", %{}, 1.5},
    {"0x1F", %{}, 31},
    {"0X1F", %{}, 31},
    {"1e2", %{}, 100.0},
    {"-5", %{}, -5},
    {"-0x10", %{}, -16},
    {"-1.5e2", %{}, -150.0},
    {"'hello'", %{}, "hello"},
    {"'it''s a test'", %{}, "it's a test"},
    {"${{ 1 }}", %{}, 1},

    # -- operators: == and != ------------------------------------------
    {"1 == 1", %{}, true},
    {"1 == 2", %{}, false},
    {"1 != 2", %{}, true},
    {"1 != 1", %{}, false},

    # -- operators: < <= > >= -------------------------------------------
    {"1 < 2", %{}, true},
    {"2 < 1", %{}, false},
    {"2 <= 2", %{}, true},
    {"3 <= 2", %{}, false},
    {"3 > 2", %{}, true},
    {"2 > 3", %{}, false},
    {"2 >= 2", %{}, true},
    {"1 >= 2", %{}, false},
    {"'apple' < 'banana'", %{}, true},

    # -- operators: && || ! ----------------------------------------------
    {"true && true", %{}, true},
    {"true && false", %{}, false},
    {"false && true", %{}, false},
    {"false || true", %{}, true},
    {"false || false", %{}, false},
    {"true || false", %{}, true},
    {"!true", %{}, false},
    {"!false", %{}, true},
    {"!(1 == 2)", %{}, true},
    {"1 < 2 && 2 < 3", %{}, true},
    {"1 > 2 || 3 > 2", %{}, true},
    {"(1 == 1) && (2 == 2)", %{}, true},

    # -- property + index access (missing -> null, never raise) --------
    {"github.event_name", %{"github" => %{"event_name" => "push"}}, "push"},
    {"github.event_name == 'push'", %{"github" => %{"event_name" => "push"}}, true},
    {"github.missing_field", %{"github" => %{}}, nil},
    {"github", %{}, nil},
    {"github.event.commits[0].message", %{}, nil},
    {"github.event.commits[0].message", %{"github" => %{"event" => %{"commits" => []}}}, nil},
    {"list[1]", %{"list" => [10, 20, 30]}, 20},
    {"list[10]", %{"list" => [1, 2, 3]}, nil},
    {"obj['a']", %{"obj" => %{"a" => 1}}, 1},
    {"items[1].name", %{"items" => [%{"name" => "x"}, %{"name" => "y"}]}, "y"},
    {"items[5].name", %{"items" => [%{"name" => "x"}]}, nil},
    {"GITHUB.REF", %{"github" => %{"ref" => "refs/heads/main"}}, "refs/heads/main"},

    # -- function: contains (strings and arrays) -------------------------
    {"contains('Hello World', 'world')", %{}, true},
    {"contains('Hello World', 'xyz')", %{}, false},
    {"contains(arr, 'b')", %{"arr" => ["a", "b", "c"]}, true},
    {"contains(arr, 'z')", %{"arr" => ["a", "b", "c"]}, false},
    {"contains(arr, 2)", %{"arr" => [1, 2, 3]}, true},
    {"contains(arr, 5)", %{"arr" => [1, 2, 3]}, false},

    # -- function: startsWith / endsWith (also demonstrate case-insensitive
    #    string comparison, per GitHub Actions docs) ----------------------
    {"startsWith('HelloWorld', 'hello')", %{}, true},
    {"startsWith('HelloWorld', 'HELLO')", %{}, true},
    {"startsWith('HelloWorld', 'world')", %{}, false},
    {"endsWith('HelloWorld', 'WORLD')", %{}, true},
    {"endsWith('HelloWorld', 'world')", %{}, true},
    {"endsWith('HelloWorld', 'hello')", %{}, false},

    # -- function: format (escaped {{ }} braces) --------------------------
    {"format('Hello {0}', 'World')", %{}, "Hello World"},
    {"format('{0} and {1}', 'a', 'b')", %{}, "a and b"},
    {"format('literal {{0}} brace', 'x')", %{}, "literal {0} brace"},
    {"format('{{}} no placeholder')", %{}, "{} no placeholder"},

    # -- function: join (custom separator, and default) -------------------
    {"join(arr, '-')", %{"arr" => ["a", "b", "c"]}, "a-b-c"},
    {"join(arr, ', ')", %{"arr" => [1, 2, 3]}, "1, 2, 3"},
    {"join(arr)", %{"arr" => ["x", "y"]}, "x,y"},

    # -- function: toJSON / fromJSON round-trip ---------------------------
    {"toJSON(1)", %{}, "1"},
    {"toJSON('hi')", %{}, "\"hi\""},
    {"fromJSON('[1,2,3]')", %{}, [1, 2, 3]},
    {"fromJSON('{\"a\":1}')", %{}, %{"a" => 1}},
    {"toJSON(fromJSON('[1,2,3]'))", %{}, "[1,2,3]"},
    {"toJSON(fromJSON('{\"a\":1}'))", %{}, "{\"a\":1}"},
    {"fromJSON(toJSON(obj)) == obj", %{"obj" => %{"a" => 1, "b" => "two"}}, true},
    {"toJSON(obj)", %{"obj" => %{"x" => 1, "y" => 2}}, Jason.encode!(%{"x" => 1, "y" => 2})},

    # -- GitHub coercion edge cases ----------------------------------------
    {"null == ''", %{}, true},
    {"'1' == 1", %{}, true},
    {"1 == '1'", %{}, true},
    {"true == 1", %{}, true},
    {"false == 0", %{}, true},
    {"'0' == false", %{}, true},
    {"'' == false", %{}, true},
    {"1 == '1.0'", %{}, true},
    {"'abc' == 1", %{}, false},
    {"'abc' == 'ABC'", %{}, true},
    {"contains('CASE Insensitive', 'INSENSITIVE')", %{}, true},
    {"contains(arr, 'B')", %{"arr" => ["a", "b", "c"]}, true},

    # -- always/success/failure/cancelled against a job-status (needs) context
    {"always()", %{}, true},
    {"always()", %{"needs" => %{"build" => %{"result" => "failure"}}}, true},
    {"success()", %{}, true},
    {"success()", %{"needs" => %{}}, true},
    {"success()", %{"needs" => %{"build" => %{"result" => "success"}}}, true},
    {"success()", %{"needs" => %{"build" => %{"result" => "failure"}}}, false},
    {"failure()", %{}, false},
    {"failure()", %{"needs" => %{"build" => %{"result" => "success"}}}, false},
    {"failure()", %{"needs" => %{"build" => %{"result" => "failure"}}}, true},
    {"cancelled()", %{}, false},
    {"cancelled()", %{"needs" => %{"build" => %{"result" => "cancelled"}}}, true},
    {"cancelled()",
     %{"needs" => %{"a" => %{"result" => "success"}, "b" => %{"result" => "cancelled"}}}, true},
    {"always() && failure()", %{"needs" => %{"build" => %{"result" => "failure"}}}, true},
    {"needs.build.result == 'success'", %{"needs" => %{"build" => %{"result" => "success"}}},
     true}
  ]

  test "table-driven expression conformance vectors" do
    results =
      Enum.map(@vectors, fn {expression, context, expected} = vector ->
        case ExpressionEvaluator.evaluate(expression, context) do
          {:ok, ^expected} -> :ok
          other -> {:mismatch, vector, other}
        end
      end)

    vectors = length(@vectors)
    failures = Enum.reject(results, &(&1 == :ok))
    failure_count = length(failures)

    IO.puts("vectors=#{vectors} failures=#{failure_count}")

    for {:mismatch, {expression, context, expected}, actual} <- failures do
      IO.inspect(%{expression: expression, context: context, expected: expected, actual: actual},
        label: "conformance mismatch"
      )
    end

    assert vectors >= 60
    assert failure_count == 0
  end
end
