defmodule CrestCiGateway.TokenIssuerTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.RunnerToken
  alias CrestCiGateway.TokenIssuer

  @signing_key "shared-signing-key-please-rotate-me"
  @future System.system_time(:second) + 3600
  @past System.system_time(:second) - 1

  test "mint returns a RunnerToken carrying the requested claims" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @future)

    assert %RunnerToken{
             runner_name: "runner-1",
             job_name: "job-1",
             expires_at: @future
           } = token

    assert is_binary(token.token)
  end

  test "verify accepts a freshly minted, unexpired token and returns its claims" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @future)

    assert {:ok, claims} = TokenIssuer.verify(@signing_key, token.token)
    assert claims.runner_name == "runner-1"
    assert claims.job_name == "job-1"
    assert claims.expires_at == @future
  end

  test "a token minted by one holder of the signing key verifies successfully under any other holder of the same key" do
    # Simulates cross-replica verification: mint using one in-memory copy of
    # the key, verify using an entirely separate copy — no shared process
    # state, no lookup, just the token bytes and the key.
    minting_key = <<@signing_key::binary>>
    verifying_key = <<@signing_key::binary>>

    token = TokenIssuer.mint(minting_key, "runner-7", "job-7", @future)

    assert {:ok, %{runner_name: "runner-7", job_name: "job-7"}} =
             TokenIssuer.verify(verifying_key, token.token)
  end

  test "verify rejects an expired token with :expired" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @past)

    assert {:error, :expired} = TokenIssuer.verify(@signing_key, token.token)
  end

  test "verify rejects a token signed with a different key as :invalid" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @future)

    assert {:error, :invalid} = TokenIssuer.verify("a-completely-different-key", token.token)
  end

  test "verify rejects a token whose payload bytes were tampered with as :invalid" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @future)
    [payload_b64, signature_b64] = String.split(token.token, ".", parts: 2)

    tampered_payload =
      payload_b64
      |> String.reverse()

    tampered_token = tampered_payload <> "." <> signature_b64

    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, tampered_token)
  end

  test "verify rejects a token whose signature bytes were tampered with as :invalid" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @future)
    [payload_b64, signature_b64] = String.split(token.token, ".", parts: 2)

    tampered_token = payload_b64 <> "." <> String.reverse(signature_b64)

    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, tampered_token)
  end

  test "verify rejects structurally malformed garbage without crashing" do
    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, "not-a-real-token")
    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, "")
    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, "only.two.dots.here")
  end

  test "an expired-and-tampered token is reported as :invalid, never :expired" do
    token = TokenIssuer.mint(@signing_key, "runner-1", "job-1", @past)
    [payload_b64, signature_b64] = String.split(token.token, ".", parts: 2)

    tampered_token = String.reverse(payload_b64) <> "." <> signature_b64

    assert {:error, :invalid} = TokenIssuer.verify(@signing_key, tampered_token)
  end
end
