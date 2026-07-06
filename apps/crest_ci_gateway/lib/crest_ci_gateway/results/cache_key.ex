defmodule CrestCiGateway.Results.CacheKey do
  @moduledoc """
  Value object: the exact cache key used to address a cache entry, e.g.
  `"deps-otp27-a1b2c3"`.

  A `CacheKey` is opaque to this system — it is whatever string the
  workflow author chose — but it must be non-empty, and equality is
  case-sensitive: `"Deps-Key"` and `"deps-key"` name different cache
  entries.

  This module holds no process state and performs no I/O — it is a pure
  parsing/validation boundary. Constructing a `%CacheKey{}` is the only
  way to obtain one; there is no way to bypass validation and still end
  up with the struct.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @doc """
  Parses a raw string into a `CacheKey`.

  Rejects:
    * empty strings (no trimming is performed — an all-whitespace string
      is a valid, distinct cache key, not a blank one)
    * any non-binary input

  ## Examples

      iex> CrestCiGateway.Results.CacheKey.new("deps-otp27-a1b2c3")
      {:ok, %CrestCiGateway.Results.CacheKey{value: "deps-otp27-a1b2c3"}}

      iex> CrestCiGateway.Results.CacheKey.new("")
      {:error, :blank}
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, :blank | :not_a_string}
  def new(raw) when is_binary(raw) do
    if raw == "" do
      {:error, :blank}
    else
      {:ok, %__MODULE__{value: raw}}
    end
  end

  def new(_raw), do: {:error, :not_a_string}

  @doc """
  Parses a raw string into a `CacheKey`, raising on invalid input.

  Intended for call sites that have already validated the input at a
  system boundary (e.g. after a prior `new/1` call) and want to avoid
  re-threading a tagged tuple.
  """
  @spec new!(String.t()) :: t()
  def new!(raw) do
    case new(raw) do
      {:ok, cache_key} -> cache_key
      {:error, reason} -> raise ArgumentError, "invalid cache key #{inspect(raw)}: #{reason}"
    end
  end

  @doc """
  Returns the underlying string value.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  @doc """
  Case-sensitive equality between two `CacheKey`s.

  Named explicitly (rather than relying on `==` at call sites) because
  case-sensitivity is a load-bearing invariant here: `"Deps-Key"` and
  `"deps-key"` must never be treated as the same cache entry.

  ## Examples

      iex> {:ok, a} = CrestCiGateway.Results.CacheKey.new("deps-key")
      iex> {:ok, b} = CrestCiGateway.Results.CacheKey.new("deps-key")
      iex> CrestCiGateway.Results.CacheKey.equal?(a, b)
      true

      iex> {:ok, a} = CrestCiGateway.Results.CacheKey.new("Deps-Key")
      iex> {:ok, b} = CrestCiGateway.Results.CacheKey.new("deps-key")
      iex> CrestCiGateway.Results.CacheKey.equal?(a, b)
      false
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a === b
end
