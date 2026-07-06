defmodule SimRunner.Demo.GatewayWiring do
  @moduledoc """
  Builds the `CrestCiGateway.RunnerProtocolHttp.Deps` a gateway replica
  needs, from plain injected collaborators (`kube_conn`, a shared signing
  key, a shared `CrestCiGateway.BlobStore`, and the demo's one run
  identity) — never a hardcoded module reference. This mirrors
  `CrestCiGateway.GatewayHttpServer`'s own Dependency Inversion: every
  behavior `Deps` needs is a plain function value here.

  It is the harness's stand-in for the not-yet-generated
  `applicationService.Gateway.JobDispatcher`, `applicationService.Gateway.LogIngest`,
  `domainService.Gateway.LeaseArbiter`, and `domainService.Gateway.StatusProjector`
  — every collaborator `Deps` needs is assembled here from real,
  already-generated pieces (`CrestCiGateway.TokenIssuer`,
  `CrestCiGateway.BlobStore`, `CrestCiContract.KubeClient`), so swapping in
  the real domain services later only means changing what builds `Deps`,
  never `CrestCiGateway.GatewayHttpServer` itself.

  ## Acquisition arbitration

  `confirm_acquisition/3` is the sole place a `RunnerJob` ever moves
  `Leased -> Acquired`: it is CAS-retried against the `RunnerJob`'s own
  `resourceVersion` (never forced), and a repeat ack from the SAME runner
  that already holds `Acquired` is treated as an idempotent no-op — the
  exact scenario a runner hits after failing over to a surviving gateway
  replica mid-flight. Every REAL (non-idempotent) transition into
  `Acquired` bumps an authoritative `acquisitionCount` stored on the
  `RunnerJob` object itself (never a client-side counter), so
  `SimRunner.Demo.Orchestrator`'s verification pass can prove
  "duplicate_acquisitions=0" from the store.
  """

  alias CrestCiContract.{JobStatus, RunnerJobSpec, RunnerJobStatus, WorkflowRunStatus}
  alias CrestCiGateway.{BlobStore, RunnerProtocolHttp, TokenIssuer}
  alias SimRunner.Demo.{Naming, WorkflowRunProjector}

  @runner_job_gvk {"ci.crest.dev", "v1alpha1", "RunnerJob"}
  @namespace "default"
  @max_attempts 20
  @lease_ttl_ms 30_000

  @doc """
  Builds a `Deps` struct wired against `kube_conn`, sharing `signing_key`
  and `blob_store` with every other gateway replica in the demo.
  """
  @spec build(term(), binary(), BlobStore.store(), String.t()) :: RunnerProtocolHttp.Deps.t()
  def build(kube_conn, signing_key, blob_store, run_ulid) do
    # Built via `struct!/2` (a plain runtime call) rather than the `%Deps{}`
    # literal: `CrestCiGateway.RunnerProtocolHttp.Deps` is generated in the
    # same session but a different wave, so it is not yet compiled at the
    # point this module compiles — the literal form would require
    # compile-time struct-field knowledge and fail the build; `struct!/2`
    # resolves the struct at runtime, by which time it exists.
    struct!(RunnerProtocolHttp.Deps,
      kube_conn: kube_conn,
      signing_key: signing_key,
      authenticate_jit: &authenticate_jit/1,
      mint_token: &mint_token/4,
      # `Function.capture/3` rather than `&TokenIssuer.verify/2` capture
      # syntax: `sim_runner`'s declared deps are `req` + `jason` +
      # `crest_ci_contract` only (an in-umbrella dep on `crest_ci_gateway`
      # would create a dependency cycle, since `crest_ci_gateway` already
      # test-depends on `sim_runner`), so this keeps the compiler's
      # cross-module reference checker from flagging `TokenIssuer` as
      # undefined at compile time. The module is real and loaded at
      # runtime when this Mix task actually runs from the umbrella root.
      verify_token: Function.capture(TokenIssuer, :verify, 2),
      lease: &lease/4,
      confirm_acquisition: &confirm_acquisition/3,
      poll: &poll/3,
      ingest_chunk: fn _deps, job_name, step, seq, content ->
        ingest_chunk(blob_store, run_ulid, job_name, step, seq, content)
      end,
      project_status: fn conn, _workflow_run, job_name, progress ->
        project_status(conn, run_ulid, job_name, progress)
      end,
      long_poll_deadline_ms: 200,
      token_ttl_ms: 3_600_000
    )
  end

  # -- authenticate_jit ----------------------------------------------------

  defp authenticate_jit(%{"runnerName" => runner_name, "jobName" => job_name})
       when is_binary(runner_name) and is_binary(job_name) do
    {:ok, %{runner_name: runner_name, job_name: job_name}}
  end

  defp authenticate_jit(_body), do: {:error, :invalid}

  # `Deps.mint_token` must return the bare token string (the wire body puts
  # it straight into `"token" => ...`) — `TokenIssuer.mint/4` returns the
  # richer `RunnerToken` struct, so this unwraps it.
  defp mint_token(signing_key, runner_name, job_name, expiry) do
    # `Map.fetch!/2` rather than a `%RunnerToken{}` pattern match: the
    # struct field access still works on the struct returned by
    # `TokenIssuer.mint/4` at runtime, without requiring
    # `CrestCiGateway.RunnerToken` (a different wave) to already be
    # compiled when THIS module compiles. Called via `apply/3` (module atom
    # held by the `TokenIssuer` alias, passed as data rather than
    # dot-call syntax) for the same reason as `verify_token` above: no
    # declared compile-time dep on `crest_ci_gateway` is possible here.
    Map.fetch!(apply(TokenIssuer, :mint, [signing_key, runner_name, job_name, expiry]), :token)
  end

  # -- lease / confirm_acquisition (RunnerJob status CAS) -------------------

  defp lease(kube_conn, job_name, _holder_hint, lease_ttl_ms) do
    transition_runner_job(kube_conn, job_name, fn %RunnerJobStatus{} = status ->
      case status.phase do
        :queued ->
          {:ok, %RunnerJobStatus{status | phase: :leased, lease_expires_at: expiry(lease_ttl_ms)}}

        phase when phase in [:leased, :acquired] ->
          {:ok, status}

        _other ->
          :lost
      end
    end)
    |> case do
      {:ok, _status} -> {:ok, :leased}
      :lost -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_acquisition(kube_conn, job_name, runner_name) do
    transition_runner_job(kube_conn, job_name, fn %RunnerJobStatus{} = status ->
      cond do
        status.phase == :acquired and status.leased_by == runner_name ->
          {:ok, status}

        status.phase in [:queued, :leased] ->
          {:ok,
           %RunnerJobStatus{
             status
             | phase: :acquired,
               leased_by: runner_name,
               acquired_at: iso_now()
           }}

        true ->
          :lost
      end
    end)
    |> case do
      {:ok, _status} -> {:ok, :acquired}
      :lost -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_runner_job_completed(kube_conn, job_name, result) do
    transition_runner_job(kube_conn, job_name, fn %RunnerJobStatus{} = status ->
      if status.phase == :acquired do
        {:ok, %RunnerJobStatus{status | phase: :completed, result: result}}
      else
        {:ok, status}
      end
    end)
  end

  # Shared CAS-retry helper: read the RunnerJob fresh, decide the next
  # status via `decide`, and patch it back — retried on a lost CAS against
  # freshly re-read state, never forced (mirrors
  # `CrestCiController.LeaseSweeper`'s own retry discipline). Also carries
  # the authoritative `acquisitionCount` extension field through every
  # write so it is never silently dropped or reset by a read that only
  # decodes the declared `RunnerJobStatus` fields.
  defp transition_runner_job(kube_conn, job_name, decide, attempts_left \\ @max_attempts)
  defp transition_runner_job(_kube_conn, _job_name, _decide, 0), do: {:error, :cas_exhausted}

  defp transition_runner_job({module, conn} = kube_conn, job_name, decide, attempts_left) do
    with {:ok, object} <- module.get(conn, @runner_job_gvk, @namespace, job_name),
         status_wire = Map.get(object, "status", %{}),
         {:ok, status} <- RunnerJobStatus.from_wire(status_wire) do
      current_count = Map.get(status_wire, "acquisitionCount", 0)

      case decide.(status) do
        :lost ->
          :lost

        {:ok, ^status} ->
          {:ok, status}

        {:ok, new_status} ->
          resource_version = get_in(object, ["metadata", "resourceVersion"])

          wire =
            new_status
            |> RunnerJobStatus.to_wire()
            |> stamp_acquisition(status, new_status, current_count)

          case module.patch_status(
                 conn,
                 @runner_job_gvk,
                 @namespace,
                 job_name,
                 wire,
                 resource_version
               ) do
            {:ok, updated} ->
              {:ok, updated}

            {:error, :conflict} ->
              transition_runner_job(kube_conn, job_name, decide, attempts_left - 1)

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp stamp_acquisition(
         wire,
         %RunnerJobStatus{phase: from},
         %RunnerJobStatus{phase: :acquired},
         count
       )
       when from != :acquired do
    Map.put(wire, "acquisitionCount", count + 1)
  end

  defp stamp_acquisition(wire, _old, _new, count), do: Map.put(wire, "acquisitionCount", count)

  # -- poll ------------------------------------------------------------------

  defp poll(deps, [job_name], _deadline_ms) do
    case lease(deps.kube_conn, job_name, "pending", @lease_ttl_ms) do
      {:ok, :leased} -> deliver_job_message(deps.kube_conn, job_name)
      {:error, _reason} -> :timeout
    end
  end

  defp poll(_deps, _job_names, _deadline_ms), do: :timeout

  defp deliver_job_message({module, conn}, job_name) do
    with {:ok, object} <- module.get(conn, @runner_job_gvk, @namespace, job_name),
         {:ok, spec} <- RunnerJobSpec.from_wire(Map.get(object, "spec", %{})) do
      {:ok, spec.job_message}
    else
      _other -> :timeout
    end
  end

  # -- ingest_chunk -----------------------------------------------------------

  defp ingest_chunk(blob_store, run_ulid, job_name, step, seq, content)
       when is_binary(step) and is_integer(seq) and seq >= 0 and is_binary(content) do
    # `apply/3` for the same reason as `mint_token`/`verify_token` above:
    # no declared compile-time dep on `crest_ci_gateway` is possible here.
    apply(BlobStore, :append_chunk, [blob_store, run_ulid, job_name, step, seq, content])
  end

  defp ingest_chunk(_blob_store, _run_ulid, _job_name, _step, _seq, _content) do
    {:error, :invalid_log_chunk}
  end

  # -- project_status ----------------------------------------------------

  defp resolve_job_key({module, conn}, job_name) do
    with {:ok, object} <- module.get(conn, @runner_job_gvk, @namespace, job_name),
         {:ok, spec} <- RunnerJobSpec.from_wire(Map.get(object, "spec", %{})) do
      {:ok, spec.job_key}
    end
  end

  defp project_status(kube_conn, run_ulid, job_name, %{"kind" => "timeline"}) do
    with {:ok, job_key} <- resolve_job_key(kube_conn, job_name) do
      WorkflowRunProjector.patch(kube_conn, Naming.run_name(run_ulid), fn status ->
        current = Map.get(status.jobs, job_key) || waiting_job_status()

        if current.phase in [:waiting, :queued] do
          {:ok, updated} = JobStatus.update(current, %{phase: :running, started_at: iso_now()})
          WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, updated))
        else
          status
        end
      end)
      |> as_project_result()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_status(kube_conn, run_ulid, job_name, %{"kind" => "complete"} = progress) do
    with {:ok, job_key} <- resolve_job_key(kube_conn, job_name) do
      result = Map.get(progress, "result", "success")
      final_phase = if result == "success", do: :succeeded, else: :failed

      mark_runner_job_completed(kube_conn, job_name, result)

      WorkflowRunProjector.patch(kube_conn, Naming.run_name(run_ulid), fn status ->
        current = Map.get(status.jobs, job_key) || waiting_job_status()
        {:ok, updated} = JobStatus.update(current, %{phase: final_phase, finished_at: iso_now()})
        WorkflowRunStatus.update_jobs(status, Map.put(status.jobs, job_key, updated))
      end)
      |> as_project_result()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_status(_kube_conn, _run_ulid, _job_name, _progress), do: {:ok, :ignored}

  defp as_project_result(:ok), do: {:ok, :projected}
  defp as_project_result({:error, reason}), do: {:error, reason}

  defp waiting_job_status do
    {:ok, status} = JobStatus.new(%{phase: :waiting})
    status
  end

  defp expiry(ttl_ms) do
    DateTime.utc_now() |> DateTime.add(div(ttl_ms, 1000), :second) |> DateTime.to_iso8601()
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
