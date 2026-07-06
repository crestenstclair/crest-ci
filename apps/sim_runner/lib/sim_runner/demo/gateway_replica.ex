defmodule SimRunner.Demo.GatewayReplica do
  @moduledoc """
  Boots one gateway replica: a dedicated one-for-one `Supervisor` wrapping
  `CrestCiGateway.GatewayHttpServer`'s Bandit listener.

  Wrapping the listener in its own `Supervisor` (rather than handing back
  the bare Bandit pid) is what lets the demo kill a *whole replica* —
  `Process.exit(supervisor_pid, :kill)` — the same way losing a pod takes
  the process down, instead of reaching in and killing an internal
  listener process directly.
  """

  alias CrestCiGateway.{GatewayHttpServer, RunnerProtocolHttp}

  @doc """
  Starts a replica bound to `port` (`0` for an ephemeral port, the
  default) using `deps`. Returns `{:ok, supervisor_pid, base_url}`.
  """
  @spec start(RunnerProtocolHttp.Deps.t(), :inet.port_number()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def start(deps, port \\ 0)

  # Guards with `is_struct/2` (a plain runtime check, OTP 25+) rather than
  # a `%RunnerProtocolHttp.Deps{}` pattern: that struct is generated in the
  # same session but a different wave, so it is not yet compiled at the
  # point this module compiles — a literal struct pattern would require
  # compile-time struct-field knowledge and fail the build.
  def start(deps, port) when is_struct(deps, RunnerProtocolHttp.Deps) do
    child_spec = %{
      id: :gateway_http_server,
      start: {GatewayHttpServer, :serve, [deps, port]},
      restart: :temporary
    }

    with {:ok, supervisor} <- Supervisor.start_link([child_spec], strategy: :one_for_one) do
      bandit_pid = bandit_pid_of(supervisor)

      # `apply/3` rather than `GatewayHttpServer.bound_port/1` dot-call
      # syntax: `sim_runner`'s declared deps are `req` + `jason` +
      # `crest_ci_contract` only (an in-umbrella dep on `crest_ci_gateway`
      # would create a dependency cycle, since `crest_ci_gateway` already
      # test-depends on `sim_runner`), so this keeps the compiler's
      # cross-module reference checker from flagging `GatewayHttpServer` as
      # undefined at compile time. The module is real and loaded at
      # runtime when this Mix task actually runs from the umbrella root.
      case apply(GatewayHttpServer, :bound_port, [bandit_pid]) do
        {:ok, bound_port} -> {:ok, supervisor, "http://127.0.0.1:#{bound_port}"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp bandit_pid_of(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn {_id, pid, _type, _modules} -> is_pid(pid) and pid end)
  end
end
