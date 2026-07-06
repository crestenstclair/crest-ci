defmodule CrestCiController.Engine.ExprValue do
  @moduledoc """
  The closed result shape of a single evaluated GitHub-Actions-style
  `${{ }}` expression: `Null | Bool | Number | String`.

  This is the C1-tier engine's value object for
  `valueObject.Engine.ExprValue` (see `spec/engine.cue`). It is
  represented as a plain Elixir term at rest — `nil | boolean() |
  number() | String.t()` — rather than a wrapping struct, so that
  `CrestCiController.Engine.ExpressionEvaluator` (and any other
  consumer) can produce and pass around results without an extra
  boxing/unboxing step. This module is the single place the *shape*
  (`valid?/1`) and GitHub's scalar coercion rules (`truthy?/1`,
  `loose_equal?/2`) are named and specified independently of any one
  consumer.

  Scope is intentionally narrow to the workflow/job tier: step-level
  expressions ship to the runner unevaluated (GitHub's own split), so
  this module never needs to represent arrays or objects as a *final*
  result — those only ever appear as intermediate context values while
  a consumer walks a property/index chain, never as the outer-boundary
  value this type describes.

  Pure value object: no processes, no I/O, no clock reads. Identical
  input always produces an identical result.
  """

  @type t :: nil | boolean() | number() | String.t()

  @doc """
  Returns `true` when `term` is a member of the closed `ExprValue`
  shape — `nil`, a `boolean()`, a `number()`, or a `String.t()` — and
  `false` for anything else (including lists and maps, which are valid
  intermediate context values but never a final `ExprValue`).

  ## Examples

      iex> CrestCiController.Engine.ExprValue.valid?(nil)
      true

      iex> CrestCiController.Engine.ExprValue.valid?("ok")
      true

      iex> CrestCiController.Engine.ExprValue.valid?(%{})
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true
  def valid?(term) when is_boolean(term), do: true
  def valid?(term) when is_number(term), do: true
  def valid?(term) when is_binary(term), do: true
  def valid?(_term), do: false

  @doc """
  Names which branch of the closed shape `value` occupies:
  `:null`, `:bool`, `:number`, or `:string`.

  Returns `{:error, :not_expr_value}` for any term outside the closed
  shape (see `valid?/1`) rather than raising, matching this engine's
  never-raise-on-shape-questions discipline.

  ## Examples

      iex> CrestCiController.Engine.ExprValue.type_of(true)
      :bool

      iex> CrestCiController.Engine.ExprValue.type_of([1, 2])
      {:error, :not_expr_value}
  """
  @spec type_of(term()) :: :null | :bool | :number | :string | {:error, :not_expr_value}
  def type_of(nil), do: :null
  def type_of(value) when is_boolean(value), do: :bool
  def type_of(value) when is_number(value), do: :number
  def type_of(value) when is_binary(value), do: :string
  def type_of(_value), do: {:error, :not_expr_value}

  @doc """
  GitHub's `ToBoolean` truthiness coercion for a scalar `ExprValue`:

    * `nil` and `false` are falsy
    * `0` (integer or float) is falsy
    * `""` (the empty string) is falsy
    * every other `ExprValue` — including any non-zero number and any
      non-empty string — is truthy

  ## Examples

      iex> CrestCiController.Engine.ExprValue.truthy?(nil)
      false

      iex> CrestCiController.Engine.ExprValue.truthy?(0)
      false

      iex> CrestCiController.Engine.ExprValue.truthy?("")
      false

      iex> CrestCiController.Engine.ExprValue.truthy?("false")
      true
  """
  @spec truthy?(t()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(true), do: true
  def truthy?(n) when is_number(n), do: n != 0
  def truthy?(s) when is_binary(s), do: s != ""

  @doc """
  GitHub's loose `==` equality coercion between two `ExprValue`s:

    * two strings compare case-insensitively
    * anything else is compared numerically via GitHub's
      string-to-number coercion (`nil` -> `0`, `true` -> `1`,
      `false` -> `0`, a numeric string -> its parsed value); a value
      that does not coerce to a number (a non-numeric string) never
      equals anything, including an identical non-numeric string
      compared against a non-string — that case is only ever reached
      through the case-insensitive string branch above

  ## Examples

      iex> CrestCiController.Engine.ExprValue.loose_equal?("YES", "yes")
      true

      iex> CrestCiController.Engine.ExprValue.loose_equal?(1, true)
      true

      iex> CrestCiController.Engine.ExprValue.loose_equal?(nil, 0)
      true

      iex> CrestCiController.Engine.ExprValue.loose_equal?("abc", 0)
      false
  """
  @spec loose_equal?(t(), t()) :: boolean()
  def loose_equal?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  def loose_equal?(a, b) do
    na = to_number(a)
    nb = to_number(b)
    na != :nan and nb != :nan and na == nb
  end

  @doc """
  GitHub's string-to-number coercion used by `loose_equal?/2` and
  relational comparisons: `nil` -> `0`, `true` -> `1`, `false` -> `0`,
  a `number()` -> itself, a numeric string -> its parsed integer or
  float, anything else (including a non-numeric string) -> the `:nan`
  sentinel, which never equals or orders against anything, including
  itself.

  ## Examples

      iex> CrestCiController.Engine.ExprValue.to_number(nil)
      0

      iex> CrestCiController.Engine.ExprValue.to_number("3.5")
      3.5

      iex> CrestCiController.Engine.ExprValue.to_number("nope")
      :nan
  """
  @spec to_number(t()) :: number() | :nan
  def to_number(nil), do: 0
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(n) when is_number(n), do: n

  def to_number(s) when is_binary(s) do
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
end
