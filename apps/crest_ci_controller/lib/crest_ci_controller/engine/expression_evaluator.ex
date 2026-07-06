defmodule CrestCiController.Engine.ExpressionEvaluator do
  @moduledoc """
  Pure evaluator for a single GitHub-Actions-style `${{ }}` expression
  against a plain, string-keyed evaluation context map (the shape
  `GithubContext.to_expr_context/1` and friends produce).

  Scope is deliberately the workflow/job tier only — job `if`, job `env`
  merge, `runs-on`, and `needs` references. Step-level expressions ship
  to the runner unevaluated (the runner owns that tier); this module
  never sees them.

  No I/O, no process state, no clock reads: `evaluate/2` is a pure
  function of `(expression, context)` and identical inputs always
  produce a byte-identical result, matching the engine's overall
  determinism invariant.

  ## Result shape

  `evaluate/2` returns a plain Elixir term — `nil | boolean | number |
  String.t()` at the outer boundary (arrays/objects only ever appear as
  intermediate context values while walking a property/index chain) —
  matching the closed `Null | Bool | Number | String` shape
  `valueObject.Engine.ExprValue` describes. Coercion (truthiness, loose
  equality, ordering) is implemented locally rather than through a
  runtime call to a separate module: this evaluator is the sole
  consumer of GitHub's coercion table in this C1 slice, so keeping it
  in one pure, dependency-free module keeps `evaluate/2` testable and
  correct in complete isolation.

  ## Grammar (a scoped subset of GitHub Actions expression syntax)

    * literals: `null`, `true`, `false`, numbers (decimal, negative,
      exponent, `0x` hex), single-quoted strings (`''` is an escaped
      quote)
    * operators (lowest to highest precedence): `||`, `&&`, the
      comparison operators `== != < <= > >=` (left-associative, all one
      precedence tier), unary `!`
    * context access: bare identifiers (`github`), dotted property
      access (`github.event_name`), bracket index/property access
      (`needs['build']`, `matrix[0]`) — property names are looked up
      case-insensitively as a fallback, matching GitHub's own behavior
    * function calls: `contains`, `startsWith`, `endsWith`, `format`,
      `join`, `toJSON`, `fromJSON`, `always`, `success`, `failure`,
      `cancelled`

  Missing properties, out-of-range indices, and indexing into a scalar
  all evaluate to `null` — this module never raises for a malformed
  *access path*; only a malformed *expression* (parse error, unknown
  function, wrong arity) is reported as `{:error, _}`.

  `success()`, `failure()`, and `cancelled()` read the `"needs"` branch
  of the context (a map of job id -> `%{"result" => "success" |
  "failure" | "cancelled" | "skipped"}`, as `ContextAssembler` builds
  it). A job with no `needs` trivially satisfies `success()`, matching
  GitHub's default job condition.
  """

  @type ast ::
          {:lit, term()}
          | {:context, String.t()}
          | {:member, ast(), String.t()}
          | {:index, ast(), ast()}
          | {:not, ast()}
          | {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:cmp, :eq | :neq | :lt | :lte | :gt | :gte, ast(), ast()}
          | {:call, String.t(), [ast()]}

  @known_functions ~w(contains startsWith endsWith format join toJSON fromJSON always success failure cancelled)

  @doc """
  Evaluates `expression` (optionally wrapped in `${{ }}`, which is
  stripped) against `context`, returning the result as a plain term
  (`nil | boolean | number | String.t()`, matching the closed
  `Null | Bool | Number | String` shape `valueObject.Engine.ExprValue`
  describes).

  Returns `{:error, {:parse_error, reason}}` for malformed syntax and
  `{:error, {:eval_error, reason}}` for a structurally invalid
  expression (unknown function, wrong argument count, invalid JSON to
  `fromJSON`). A missing context property is never an error — it
  evaluates to `nil`.
  """
  @spec evaluate(String.t(), map()) ::
          {:ok, nil | boolean() | number() | String.t() | list() | map()}
          | {:error, {:parse_error, String.t()} | {:eval_error, String.t()}}
  def evaluate(expression, context) when is_binary(expression) and is_map(context) do
    source = strip_wrapper(expression)

    try do
      with {:ok, tokens} <- tokenize(source),
           {ast, []} <- parse(tokens) do
        {:ok, eval(ast, context)}
      else
        {:error, reason} ->
          {:error, {:parse_error, reason}}

        {_ast, leftover} ->
          {:error, {:parse_error, "unexpected trailing tokens: #{inspect(leftover)}"}}
      end
    catch
      {:parse_error, reason} -> {:error, {:parse_error, reason}}
      {:eval_error, reason} -> {:error, {:eval_error, reason}}
    end
  end

  @spec strip_wrapper(String.t()) :: String.t()
  defp strip_wrapper(expression) do
    trimmed = String.trim(expression)

    if String.starts_with?(trimmed, "${{") and String.ends_with?(trimmed, "}}") do
      trimmed
      |> String.slice(3..-3//1)
      |> String.trim()
    else
      trimmed
    end
  end

  # ---------------------------------------------------------------------
  # Tokenizer
  # ---------------------------------------------------------------------

  @type token ::
          :lparen
          | :rparen
          | :lbracket
          | :rbracket
          | :dot
          | :comma
          | :not
          | :eq
          | :neq
          | :lt
          | :lte
          | :gt
          | :gte
          | :and
          | :or
          | {:number, number()}
          | {:string, String.t()}
          | {:ident, String.t()}

  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  defp tokenize(str), do: do_tokenize(str, [])

  @spec do_tokenize(String.t(), [token()]) :: {:ok, [token()]} | {:error, String.t()}
  defp do_tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: do_tokenize(rest, acc)

  defp do_tokenize(<<"==", rest::binary>>, acc), do: do_tokenize(rest, [:eq | acc])
  defp do_tokenize(<<"!=", rest::binary>>, acc), do: do_tokenize(rest, [:neq | acc])
  defp do_tokenize(<<"<=", rest::binary>>, acc), do: do_tokenize(rest, [:lte | acc])
  defp do_tokenize(<<">=", rest::binary>>, acc), do: do_tokenize(rest, [:gte | acc])
  defp do_tokenize(<<"&&", rest::binary>>, acc), do: do_tokenize(rest, [:and | acc])
  defp do_tokenize(<<"||", rest::binary>>, acc), do: do_tokenize(rest, [:or | acc])
  defp do_tokenize(<<"!", rest::binary>>, acc), do: do_tokenize(rest, [:not | acc])
  defp do_tokenize(<<"<", rest::binary>>, acc), do: do_tokenize(rest, [:lt | acc])
  defp do_tokenize(<<">", rest::binary>>, acc), do: do_tokenize(rest, [:gt | acc])
  defp do_tokenize(<<"(", rest::binary>>, acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize(<<")", rest::binary>>, acc), do: do_tokenize(rest, [:rparen | acc])
  defp do_tokenize(<<"[", rest::binary>>, acc), do: do_tokenize(rest, [:lbracket | acc])
  defp do_tokenize(<<"]", rest::binary>>, acc), do: do_tokenize(rest, [:rbracket | acc])
  defp do_tokenize(<<".", rest::binary>>, acc), do: do_tokenize(rest, [:dot | acc])
  defp do_tokenize(<<",", rest::binary>>, acc), do: do_tokenize(rest, [:comma | acc])

  defp do_tokenize(<<"'", rest::binary>>, acc) do
    case scan_string(rest, "") do
      {:ok, s, rest2} -> do_tokenize(rest2, [{:string, s} | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 do
    scan_number(bin, acc)
  end

  defp do_tokenize(<<"-", c, _::binary>> = bin, acc) when c in ?0..?9 do
    scan_number(bin, acc)
  end

  defp do_tokenize(<<c, _::binary>> = bin, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ do
    scan_ident(bin, acc)
  end

  defp do_tokenize(_bin, _acc), do: {:error, "unexpected character in expression"}

  @spec scan_string(String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  defp scan_string(<<"''", rest::binary>>, acc), do: scan_string(rest, acc <> "'")
  defp scan_string(<<"'", rest::binary>>, acc), do: {:ok, acc, rest}
  defp scan_string(<<c::utf8, rest::binary>>, acc), do: scan_string(rest, acc <> <<c::utf8>>)
  defp scan_string(<<>>, _acc), do: {:error, "unterminated string literal"}

  @spec scan_number(String.t(), [token()]) :: {:ok, [token()]} | {:error, String.t()}
  defp scan_number(bin, acc) do
    case Regex.run(~r/^-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/, bin) do
      [match] ->
        rest = binary_part(bin, byte_size(match), byte_size(bin) - byte_size(match))
        do_tokenize(rest, [{:number, parse_number_literal(match)} | acc])

      nil ->
        {:error, "invalid number literal"}
    end
  end

  @spec parse_number_literal(String.t()) :: number()
  defp parse_number_literal(text) do
    {neg, unsigned} =
      if String.starts_with?(text, "-") do
        {true, String.slice(text, 1..-1//1)}
      else
        {false, text}
      end

    value =
      cond do
        String.starts_with?(String.downcase(unsigned), "0x") ->
          String.to_integer(String.slice(unsigned, 2..-1//1), 16)

        String.contains?(unsigned, ".") or String.contains?(unsigned, "e") or
            String.contains?(unsigned, "E") ->
          normalized =
            case Regex.run(~r/^(\d+)([eE].*)$/, unsigned) do
              [_, int_part, exp_part] -> int_part <> ".0" <> exp_part
              nil -> unsigned
            end

          {f, _rest} = Float.parse(normalized)
          f

        true ->
          String.to_integer(unsigned)
      end

    if neg, do: -value, else: value
  end

  @spec scan_ident(String.t(), [token()]) :: {:ok, [token()]} | {:error, String.t()}
  defp scan_ident(bin, acc) do
    [match] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_-]*/, bin)
    rest = binary_part(bin, byte_size(match), byte_size(bin) - byte_size(match))
    do_tokenize(rest, [{:ident, match} | acc])
  end

  # ---------------------------------------------------------------------
  # Parser (recursive descent; precedence low -> high: || , && , comparisons
  # (== != < <= > >=, chainable, one tier), unary !, postfix . / [ ] / call)
  # ---------------------------------------------------------------------

  @spec parse([token()]) :: {ast(), [token()]}
  defp parse(tokens), do: parse_or(tokens)

  @spec parse_or([token()]) :: {ast(), [token()]}
  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)
    do_or(left, rest)
  end

  defp do_or(left, [:or | rest]) do
    {right, rest2} = parse_and(rest)
    do_or({:or, left, right}, rest2)
  end

  defp do_or(left, rest), do: {left, rest}

  @spec parse_and([token()]) :: {ast(), [token()]}
  defp parse_and(tokens) do
    {left, rest} = parse_cmp(tokens)
    do_and(left, rest)
  end

  defp do_and(left, [:and | rest]) do
    {right, rest2} = parse_cmp(rest)
    do_and({:and, left, right}, rest2)
  end

  defp do_and(left, rest), do: {left, rest}

  @spec parse_cmp([token()]) :: {ast(), [token()]}
  defp parse_cmp(tokens) do
    {left, rest} = parse_unary(tokens)
    do_cmp(left, rest)
  end

  defp do_cmp(left, [op | rest]) when op in [:eq, :neq, :lt, :lte, :gt, :gte] do
    {right, rest2} = parse_unary(rest)
    do_cmp({:cmp, op, left, right}, rest2)
  end

  defp do_cmp(left, rest), do: {left, rest}

  @spec parse_unary([token()]) :: {ast(), [token()]}
  defp parse_unary([:not | rest]) do
    {inner, rest2} = parse_unary(rest)
    {{:not, inner}, rest2}
  end

  defp parse_unary(tokens), do: parse_postfix(tokens)

  @spec parse_postfix([token()]) :: {ast(), [token()]}
  defp parse_postfix(tokens) do
    {primary, rest} = parse_primary(tokens)
    do_postfix(primary, rest)
  end

  defp do_postfix(base, [:dot, {:ident, name} | rest]),
    do: do_postfix({:member, base, name}, rest)

  defp do_postfix(base, [:lbracket | rest]) do
    {idx_ast, rest2} = parse_or(rest)

    case rest2 do
      [:rbracket | rest3] -> do_postfix({:index, base, idx_ast}, rest3)
      _ -> throw({:parse_error, "expected ']'"})
    end
  end

  defp do_postfix(base, rest), do: {base, rest}

  @spec parse_primary([token()]) :: {ast(), [token()]}
  defp parse_primary([{:number, n} | rest]), do: {{:lit, n}, rest}
  defp parse_primary([{:string, s} | rest]), do: {{:lit, s}, rest}
  defp parse_primary([{:ident, "true"} | rest]), do: {{:lit, true}, rest}
  defp parse_primary([{:ident, "false"} | rest]), do: {{:lit, false}, rest}
  defp parse_primary([{:ident, "null"} | rest]), do: {{:lit, nil}, rest}

  defp parse_primary([{:ident, name}, :lparen | rest]) do
    {args, rest2} = parse_args(rest)
    {{:call, name, args}, rest2}
  end

  defp parse_primary([{:ident, name} | rest]), do: {{:context, name}, rest}

  defp parse_primary([:lparen | rest]) do
    {inner, rest2} = parse_or(rest)

    case rest2 do
      [:rparen | rest3] -> {inner, rest3}
      _ -> throw({:parse_error, "expected ')'"})
    end
  end

  defp parse_primary([]), do: throw({:parse_error, "unexpected end of expression"})

  defp parse_primary(tokens),
    do: throw({:parse_error, "unexpected token: #{inspect(hd(tokens))}"})

  @spec parse_args([token()]) :: {[ast()], [token()]}
  defp parse_args([:rparen | rest]), do: {[], rest}
  defp parse_args(tokens), do: parse_args_loop(tokens, [])

  defp parse_args_loop(tokens, acc) do
    {arg, rest} = parse_or(tokens)
    acc2 = [arg | acc]

    case rest do
      [:comma | rest2] -> parse_args_loop(rest2, acc2)
      [:rparen | rest2] -> {Enum.reverse(acc2), rest2}
      _ -> throw({:parse_error, "expected ',' or ')'"})
    end
  end

  # ---------------------------------------------------------------------
  # Evaluation over plain Elixir terms (nil | boolean | number | binary |
  # map | list).
  # ---------------------------------------------------------------------

  @spec eval(ast(), map()) :: term()
  defp eval({:lit, v}, _ctx), do: v
  defp eval({:context, name}, ctx), do: member_get(ctx, name)
  defp eval({:member, base_ast, name}, ctx), do: member_get(eval(base_ast, ctx), name)

  defp eval({:index, base_ast, idx_ast}, ctx),
    do: index_get(eval(base_ast, ctx), eval(idx_ast, ctx))

  defp eval({:not, inner}, ctx), do: !raw_truthy?(eval(inner, ctx))

  defp eval({:and, l, r}, ctx) do
    lv = eval(l, ctx)
    if raw_truthy?(lv), do: eval(r, ctx), else: lv
  end

  defp eval({:or, l, r}, ctx) do
    lv = eval(l, ctx)
    if raw_truthy?(lv), do: lv, else: eval(r, ctx)
  end

  defp eval({:cmp, :eq, l, r}, ctx), do: loose_equal?(eval(l, ctx), eval(r, ctx))
  defp eval({:cmp, :neq, l, r}, ctx), do: not loose_equal?(eval(l, ctx), eval(r, ctx))

  defp eval({:cmp, op, l, r}, ctx) when op in [:lt, :lte, :gt, :gte],
    do: compare(op, eval(l, ctx), eval(r, ctx))

  defp eval({:call, name, arg_asts}, ctx) do
    if name not in @known_functions do
      throw({:eval_error, "unknown function: #{name}"})
    end

    args = Enum.map(arg_asts, &eval(&1, ctx))
    call_function(name, args, ctx)
  end

  @spec call_function(String.t(), [term()], map()) :: term()
  defp call_function("contains", [a, b], _ctx), do: fn_contains(a, b)

  defp call_function("contains", _args, _ctx),
    do: throw({:eval_error, "contains expects 2 arguments"})

  defp call_function("startsWith", [a, b], _ctx),
    do:
      String.starts_with?(
        String.downcase(to_display_string(a)),
        String.downcase(to_display_string(b))
      )

  defp call_function("startsWith", _args, _ctx),
    do: throw({:eval_error, "startsWith expects 2 arguments"})

  defp call_function("endsWith", [a, b], _ctx),
    do:
      String.ends_with?(
        String.downcase(to_display_string(a)),
        String.downcase(to_display_string(b))
      )

  defp call_function("endsWith", _args, _ctx),
    do: throw({:eval_error, "endsWith expects 2 arguments"})

  defp call_function("format", [fmt | fargs], _ctx),
    do: format_string(to_display_string(fmt), fargs)

  defp call_function("format", _args, _ctx),
    do: throw({:eval_error, "format expects at least 1 argument"})

  defp call_function("join", [arr], _ctx), do: join_values(arr, ",")
  defp call_function("join", [arr, sep], _ctx), do: join_values(arr, to_display_string(sep))

  defp call_function("join", _args, _ctx),
    do: throw({:eval_error, "join expects 1 or 2 arguments"})

  defp call_function("toJSON", [v], _ctx), do: Jason.encode!(v)
  defp call_function("toJSON", _args, _ctx), do: throw({:eval_error, "toJSON expects 1 argument"})

  defp call_function("fromJSON", [v], _ctx) do
    case Jason.decode(to_display_string(v)) do
      {:ok, decoded} -> decoded
      {:error, _} -> throw({:eval_error, "fromJSON: invalid JSON"})
    end
  end

  defp call_function("fromJSON", _args, _ctx),
    do: throw({:eval_error, "fromJSON expects 1 argument"})

  defp call_function("always", [], _ctx), do: true

  defp call_function("always", _args, _ctx),
    do: throw({:eval_error, "always expects 0 arguments"})

  defp call_function("success", [], ctx), do: needs_all?(ctx, "success")

  defp call_function("success", _args, _ctx),
    do: throw({:eval_error, "success expects 0 arguments"})

  defp call_function("failure", [], ctx), do: needs_any?(ctx, "failure")

  defp call_function("failure", _args, _ctx),
    do: throw({:eval_error, "failure expects 0 arguments"})

  defp call_function("cancelled", [], ctx), do: needs_any?(ctx, "cancelled")

  defp call_function("cancelled", _args, _ctx),
    do: throw({:eval_error, "cancelled expects 0 arguments"})

  @spec fn_contains(term(), term()) :: boolean()
  defp fn_contains(a, b) when is_binary(a),
    do: String.contains?(String.downcase(a), String.downcase(to_display_string(b)))

  defp fn_contains(a, b) when is_list(a), do: Enum.any?(a, &loose_equal?(&1, b))
  defp fn_contains(_a, _b), do: false

  @spec join_values(term(), String.t()) :: String.t()
  defp join_values(arr, sep) when is_list(arr),
    do: arr |> Enum.map(&to_display_string/1) |> Enum.join(sep)

  defp join_values(other, _sep), do: to_display_string(other)

  @escaped_open "\u0001"
  @escaped_close "\u0002"

  @spec format_string(String.t(), [term()]) :: String.t()
  defp format_string(fmt, args) do
    fmt
    |> String.replace("{{", @escaped_open)
    |> String.replace("}}", @escaped_close)
    |> then(fn s ->
      Regex.replace(~r/\{(\d+)\}/, s, fn _whole, idx_str ->
        idx = String.to_integer(idx_str)

        case Enum.at(args, idx) do
          nil -> ""
          v -> to_display_string(v)
        end
      end)
    end)
    |> String.replace(@escaped_open, "{")
    |> String.replace(@escaped_close, "}")
  end

  # ---------------------------------------------------------------------
  # Context access — missing property/index/scalar-base access always
  # resolves to nil, never raises.
  # ---------------------------------------------------------------------

  @spec member_get(term(), String.t()) :: term()
  defp member_get(base, name) when is_map(base) do
    case Map.fetch(base, name) do
      {:ok, v} ->
        v

      :error ->
        down = String.downcase(name)

        Enum.find_value(base, nil, fn
          {k, v} when is_binary(k) -> if String.downcase(k) == down, do: {:found, v}
          _ -> nil
        end)
        |> case do
          {:found, v} -> v
          _ -> nil
        end
    end
  end

  defp member_get(_base, _name), do: nil

  @spec index_get(term(), term()) :: term()
  defp index_get(base, key) when is_list(base) do
    idx =
      cond do
        is_integer(key) -> key
        is_float(key) -> trunc(key)
        is_binary(key) -> string_to_index(key)
        true -> nil
      end

    if is_integer(idx) and idx >= 0 and idx < length(base) do
      Enum.at(base, idx)
    else
      nil
    end
  end

  defp index_get(base, key) when is_map(base), do: member_get(base, to_display_string(key))
  defp index_get(_base, _key), do: nil

  @spec string_to_index(String.t()) :: integer() | nil
  defp string_to_index(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------
  # Coercion — GitHub ToBoolean truthiness, loose `==`/`!=` equality, and
  # `< <= > >=` ordering. String comparisons (equality and ordering) are
  # case-insensitive, matching GitHub Actions' own documented behavior;
  # everything else is compared via `to_number/1`, whose `:nan` sentinel
  # never equals or orders against anything, including itself.
  # ---------------------------------------------------------------------

  @spec raw_truthy?(term()) :: boolean()
  defp raw_truthy?(nil), do: false
  defp raw_truthy?(false), do: false
  defp raw_truthy?(true), do: true
  defp raw_truthy?(n) when is_number(n), do: n != 0
  defp raw_truthy?(s) when is_binary(s), do: s != ""
  defp raw_truthy?(m) when is_map(m), do: true
  defp raw_truthy?(l) when is_list(l), do: true

  @spec loose_equal?(term(), term()) :: boolean()
  defp loose_equal?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp loose_equal?(a, b) when is_list(a) and is_list(b), do: a == b
  defp loose_equal?(a, b) when is_map(a) and is_map(b), do: a == b

  defp loose_equal?(a, b) do
    na = to_number(a)
    nb = to_number(b)
    na != :nan and nb != :nan and na == nb
  end

  @spec compare(:lt | :lte | :gt | :gte, term(), term()) :: boolean()
  defp compare(op, a, b) when is_binary(a) and is_binary(b) do
    da = String.downcase(a)
    db = String.downcase(b)

    case op do
      :lt -> da < db
      :lte -> da <= db
      :gt -> da > db
      :gte -> da >= db
    end
  end

  defp compare(op, a, b) do
    na = to_number(a)
    nb = to_number(b)

    if na == :nan or nb == :nan do
      false
    else
      case op do
        :lt -> na < nb
        :lte -> na <= nb
        :gt -> na > nb
        :gte -> na >= nb
      end
    end
  end

  @spec to_number(term()) :: number() | :nan
  defp to_number(nil), do: 0
  defp to_number(true), do: 1
  defp to_number(false), do: 0
  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        0

      true ->
        case Float.parse(trimmed) do
          {f, ""} ->
            f

          _ ->
            case Integer.parse(trimmed) do
              {i, ""} -> i
              _ -> :nan
            end
        end
    end
  end

  defp to_number(_other), do: :nan

  # ---------------------------------------------------------------------
  # Display-string conversion for `format`/`join`/`contains`/`startsWith`/
  # `endsWith` argument coercion — a string-rendering concern distinct
  # from the boolean/equality/order coercion table above.
  # ---------------------------------------------------------------------

  @spec to_display_string(term()) :: String.t()
  defp to_display_string(nil), do: ""
  defp to_display_string(true), do: "true"
  defp to_display_string(false), do: "false"
  defp to_display_string(n) when is_integer(n), do: Integer.to_string(n)

  defp to_display_string(n) when is_float(n) do
    if n == Float.round(n, 0) do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end

  defp to_display_string(s) when is_binary(s), do: s
  defp to_display_string(other) when is_map(other) or is_list(other), do: Jason.encode!(other)

  # ---------------------------------------------------------------------
  # needs-derived success()/failure()/cancelled()
  # ---------------------------------------------------------------------

  @spec needs_all?(map(), String.t()) :: boolean()
  defp needs_all?(ctx, wanted) do
    case Map.get(ctx, "needs") do
      needs when is_map(needs) and map_size(needs) == 0 ->
        true

      needs when is_map(needs) ->
        Enum.all?(Map.values(needs), &needs_result_is?(&1, wanted))

      _ ->
        true
    end
  end

  @spec needs_any?(map(), String.t()) :: boolean()
  defp needs_any?(ctx, wanted) do
    case Map.get(ctx, "needs") do
      needs when is_map(needs) -> Enum.any?(Map.values(needs), &needs_result_is?(&1, wanted))
      _ -> false
    end
  end

  @spec needs_result_is?(term(), String.t()) :: boolean()
  defp needs_result_is?(%{"result" => r}, wanted), do: r == wanted
  defp needs_result_is?(_other, _wanted), do: false
end
