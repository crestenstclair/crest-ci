defmodule SimRunner.RunnerClient.HttpTransport do
  @moduledoc """
  Default `SimRunner.RunnerClient.Transport` adapter: speaks the gateway's
  runner protocol v0 over HTTP via `Req`.

  This is the production collaborator injected into `SimRunner.RunnerClient`
  by default; tests inject a stub/mock implementing the same behaviour
  instead (Dependency Inversion — `RunnerClient` depends on the
  `Transport` behaviour, never on this module directly).
  """

  @behaviour SimRunner.RunnerClient.Transport

  @impl true
  def create_session(base_url, jit_config) do
    with {:ok, body} <- request(:post, base_url <> "/session", json: jit_config) do
      case body do
        %{"token" => token} -> {:ok, token}
        _ -> {:error, {:invalid_response, body}}
      end
    end
  end

  @impl true
  def poll_messages(base_url, token) do
    case request(:get, base_url <> "/session/messages", auth(token)) do
      {:ok, :no_content} -> :no_job
      {:ok, body} when is_map(body) -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ack_job(base_url, token, job_name) do
    with {:ok, _body} <- request(:post, job_url(base_url, job_name, "ack"), auth(token)) do
      :ok
    end
  end

  @impl true
  def send_log_chunk(base_url, token, job_name, step, seq, content) do
    body = %{"step" => step, "seq" => seq, "content" => content}

    with {:ok, _resp} <-
           request(
             :post,
             job_url(base_url, job_name, "logs"),
             Keyword.merge(auth(token), json: body)
           ) do
      :ok
    end
  end

  @impl true
  def send_timeline(base_url, token, job_name, step, status) do
    body = %{"step" => step, "status" => status}

    with {:ok, _resp} <-
           request(
             :post,
             job_url(base_url, job_name, "timeline"),
             Keyword.merge(auth(token), json: body)
           ) do
      :ok
    end
  end

  @impl true
  def complete_job(base_url, token, job_name, result, outputs) do
    body = %{"result" => result, "outputs" => outputs}

    with {:ok, _resp} <-
           request(
             :post,
             job_url(base_url, job_name, "complete"),
             Keyword.merge(auth(token), json: body)
           ) do
      :ok
    end
  end

  defp job_url(base_url, job_name, action), do: base_url <> "/jobs/" <> job_name <> "/" <> action

  defp auth(token), do: [headers: [{"authorization", "Bearer " <> token}]]

  defp request(method, url, opts) do
    case Req.request([method: method, url: url, retry: false] ++ opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 204}} -> {:ok, :no_content}
      {:ok, %{status: status}} when status >= 500 -> {:error, :server_error}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, _reason} -> {:error, :connection_error}
    end
  end
end
