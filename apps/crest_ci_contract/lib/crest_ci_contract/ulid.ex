defmodule CrestCiContract.Ulid do
  @moduledoc """
  A `Ulid` is a 26-character Crockford base32 ULID: a Universally Unique
  Lexicographically Sortable Identifier, derived from a 48-bit millisecond
  timestamp followed by 80 bits of randomness.

  It is a plain string value object — no wrapping struct, since both
  Kubernetes object names (via `CrestCiContract.DeterministicNaming`) and the
  JSON wire shape want a bare string.

  Two ULIDs generated at different milliseconds sort lexicographically in
  creation order, because the timestamp component is encoded first and
  Crockford base32 preserves numeric ordering under byte/character
  comparison.
  """

  import Bitwise

  @type t :: String.t()

  # Crockford base32: excludes I, L, O, U to avoid visual ambiguity.
  @crockford_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @crockford_alphabet_tuple @crockford_alphabet |> Enum.map(&<<&1>>) |> List.to_tuple()

  @timestamp_chars 10
  @randomness_chars 16
  @total_chars @timestamp_chars + @randomness_chars

  @doc """
  Generate a new `Ulid`: the current system time in milliseconds encoded as
  10 Crockford base32 characters, followed by 16 characters of
  cryptographically strong randomness.

  Not pure (reads wall-clock time and entropy), so it lives at the edge as a
  generator function rather than participating in any pure functional core.
  """
  @spec generate() :: t()
  def generate do
    timestamp_ms = System.system_time(:millisecond)
    generate(timestamp_ms, :crypto.strong_rand_bytes(10))
  end

  @doc """
  Generate a `Ulid` from an explicit timestamp (milliseconds since epoch)
  and 10 bytes of randomness. Exposed primarily for deterministic testing of
  the monotonic-ordering invariant.
  """
  @spec generate(non_neg_integer(), binary()) :: t()
  def generate(timestamp_ms, <<random::80>>)
      when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    encode_timestamp(timestamp_ms) <> encode_randomness(random)
  end

  @doc """
  Validate that a value is a well-formed `Ulid`: exactly 26 characters, all
  drawn from the Crockford base32 alphabet.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    String.length(value) == @total_chars and
      value |> String.to_charlist() |> Enum.all?(&(&1 in @crockford_alphabet))
  end

  def valid?(_value), do: false

  defp encode_timestamp(timestamp_ms) do
    encode_base32(timestamp_ms, @timestamp_chars)
  end

  defp encode_randomness(random) do
    encode_base32(random, @randomness_chars)
  end

  defp encode_base32(value, length) do
    0..(length - 1)
    |> Enum.reduce([], fn i, acc ->
      shift = i * 5
      index = value >>> shift &&& 0b11111
      [elem(@crockford_alphabet_tuple, index) | acc]
    end)
    |> Enum.join()
  end
end
