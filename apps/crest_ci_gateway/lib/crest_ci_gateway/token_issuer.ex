defmodule CrestCiGateway.TokenIssuer do
  @moduledoc """
  Mints and verifies `CrestCiGateway.RunnerToken` values.

  A token is `base64url(payload) <> "." <> base64url(hmac_sha256(key, payload))`
  where `payload` is the exact `:erlang.term_to_binary/1` encoding of
  `{runner_name, job_name, expires_at}`. Signing the raw payload bytes (not a
  re-derived encoding of them) means verification never needs to reconstruct
  anything from a lookup — the claims travel inside the token, so `verify/2`
  is a pure function of `(signing_key, token)`. Any gateway replica holding
  the same shared `signing_key` therefore verifies any token minted by any
  other replica identically; no session store, no coordination, no lookup.

  `verify/2` never touches the Kubernetes API or any other store — it is a
  local, deterministic computation over the token bytes and the key. That is
  precisely what lets callers (the HTTP layer) reject an expired or tampered
  token with `401` before any store access is even attempted: the rejection
  happens entirely inside this module, before a caller could reach a store.

  Order of checks in `verify/2` matters: the HMAC signature is checked
  before the payload is decoded or inspected, and before expiry is checked.
  A tampered token is therefore rejected as `{:error, :invalid}` without
  ever trusting attacker-controlled bytes; only a token that already carries
  a valid signature has its expiry inspected.
  """

  alias CrestCiGateway.RunnerToken

  @type signing_key :: binary()
  @type claims :: %{runner_name: String.t(), job_name: String.t(), expires_at: integer()}

  @doc """
  Mint a new `RunnerToken` scoping `runner_name` to `job_name`, expiring at
  the unix-seconds timestamp `expiry`. Pure: no I/O, no store access —
  the signed token is entirely reconstructible from `signing_key` and the
  three claims.
  """
  @spec mint(signing_key(), String.t(), String.t(), integer()) :: RunnerToken.t()
  def mint(signing_key, runner_name, job_name, expiry)
      when is_binary(signing_key) and is_binary(runner_name) and is_binary(job_name) and
             is_integer(expiry) do
    payload = :erlang.term_to_binary({runner_name, job_name, expiry})
    signature = sign(signing_key, payload)

    token =
      Base.url_encode64(payload, padding: false) <>
        "." <> Base.url_encode64(signature, padding: false)

    %RunnerToken{
      token: token,
      runner_name: runner_name,
      job_name: job_name,
      expires_at: expiry
    }
  end

  @doc """
  Verify `token` against `signing_key`.

  Returns `{:ok, claims}` when the signature is intact and the token has not
  yet expired. Returns `{:error, :invalid}` for any structurally malformed
  or tampered token (bad base64, wrong signature, corrupted term bytes) and
  `{:error, :expired}` only once the signature has already been confirmed
  valid — an expired-but-forged token is `:invalid`, never `:expired`.

  This function performs no Kubernetes API calls and no store lookups of
  any kind; it is safe to call before any store access is attempted.
  """
  @spec verify(signing_key(), String.t()) :: {:ok, claims()} | {:error, :expired | :invalid}
  def verify(signing_key, token) when is_binary(signing_key) and is_binary(token) do
    with [payload_b64, signature_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, signature} <- Base.url_decode64(signature_b64, padding: false),
         true <- secure_equal?(sign(signing_key, payload), signature),
         {:ok, claims} <- decode_payload(payload) do
      if expired?(claims.expires_at) do
        {:error, :expired}
      else
        {:ok, claims}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  # -- internal --------------------------------------------------------

  defp sign(signing_key, payload) do
    :crypto.mac(:hmac, :sha256, signing_key, payload)
  end

  defp decode_payload(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {runner_name, job_name, expires_at}
      when is_binary(runner_name) and is_binary(job_name) and is_integer(expires_at) ->
        {:ok, %{runner_name: runner_name, job_name: job_name, expires_at: expires_at}}

      _other ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp expired?(expires_at) do
    System.system_time(:second) >= expires_at
  end

  # Constant-time comparison: byte-length is checked up front (both HMAC
  # outputs are fixed-length, so this leaks nothing useful), then every
  # byte pair is compared regardless of an earlier mismatch so total time
  # depends only on length, never on where the first differing byte is.
  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      a
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(b))
      |> Enum.reduce(0, fn {x, y}, acc -> :erlang.bor(acc, :erlang.bxor(x, y)) end)
      |> Kernel.==(0)
    else
      false
    end
  end
end
