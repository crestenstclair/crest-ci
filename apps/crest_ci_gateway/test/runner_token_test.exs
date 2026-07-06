defmodule CrestCiGateway.RunnerTokenTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.RunnerToken

  test "struct requires token, runner_name, job_name, and expires_at" do
    token = %RunnerToken{
      token: "opaque-signed-bytes",
      runner_name: "runner-1",
      job_name: "job-1",
      expires_at: 1_000_000
    }

    assert token.token == "opaque-signed-bytes"
    assert token.runner_name == "runner-1"
    assert token.job_name == "job-1"
    assert token.expires_at == 1_000_000
  end

  test "enforced keys raise if omitted" do
    assert_raise ArgumentError, fn ->
      Code.eval_quoted(
        quote do
          %RunnerToken{runner_name: "runner-1"}
        end
      )
    end
  end
end
