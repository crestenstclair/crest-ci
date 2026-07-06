defmodule CrestCiGateway.RunnerToken do
  @moduledoc """
  Value Object: `valueObject.Gateway.RunnerToken` — a signed, self-contained
  bearer token scoping a runner to its one `RunnerJob`.

  A `RunnerToken` carries everything a gateway replica needs to authenticate
  a runner request — runner name, job name, and expiry — inside the signed
  `token` binary itself. No replica-local or store lookup is ever required to
  validate one: any replica holding the shared HMAC signing key can verify a
  token unassisted (see `CrestCiGateway.TokenIssuer`). This is what lets an
  active-active gateway treat "reconnected to a different replica" and
  "stayed on the same replica" as indistinguishable — session identity is
  re-derivable from the token on every request, never from replica memory.

  This struct is pure data. Minting and verification live in
  `CrestCiGateway.TokenIssuer`, which depends on this module rather than the
  other way around.
  """

  @enforce_keys [:token, :runner_name, :job_name, :expires_at]
  defstruct [:token, :runner_name, :job_name, :expires_at]

  @type t :: %__MODULE__{
          token: String.t(),
          runner_name: String.t(),
          job_name: String.t(),
          expires_at: integer()
        }
end
