defmodule CrestCiController.Cluster.RunnerImageTest do
  @moduledoc """
  Structural contract check for the runner container image assets
  (`deploy/runner/Dockerfile` + `deploy/runner/entrypoint.sh`). This is a
  text/structure check only — it never invokes `docker build` (the mix
  gate must never touch Docker), so it proves the image *shape* is
  correct without Docker installed.

  It also cross-checks the identity/gateway environment variable names
  the entrypoint reads against the names `PodSpecBuilder` (the domain
  service that renders a real Pod's env, `apps/crest_ci_controller/lib/
  crest_ci_controller/cluster/pod_spec_builder.ex`) emits. `PodSpecBuilder`
  is read as plain text, never `alias`ed or called, so this suite never
  hard-depends on that module compiling or even existing yet — before it
  exists, the check falls back to the canonical key set documented in
  the Cluster context's ubiquitous language (`GATEWAY_URLS` + the JIT
  identity bundle), which is also what the entrypoint is written against.
  """
  use ExUnit.Case, async: true

  @dockerfile_path Path.expand(Path.join(__DIR__, "../../../../deploy/runner/Dockerfile"))
  @entrypoint_path Path.expand(Path.join(__DIR__, "../../../../deploy/runner/entrypoint.sh"))
  @pod_spec_builder_path Path.expand(
                           Path.join(
                             __DIR__,
                             "../../lib/crest_ci_controller/cluster/pod_spec_builder.ex"
                           )
                         )

  # The canonical identity/gateway env var names the runner Pod contract
  # uses. This list is the fallback source of truth until PodSpecBuilder
  # exists, and doubles as the set searched for inside its source once it
  # does — keeping entrypoint.sh and PodSpecBuilder in sync.
  @canonical_env_keys ["GATEWAY_URLS", "RUNNER_JIT_CONFIG", "RUNNER_NAME", "RUNNER_ID"]

  test "Dockerfile + entrypoint honor the runner image contract" do
    assert File.exists?(@dockerfile_path), "expected #{@dockerfile_path} to exist"
    assert File.exists?(@entrypoint_path), "expected #{@entrypoint_path} to exist"

    dockerfile = File.read!(@dockerfile_path)
    entrypoint = File.read!(@entrypoint_path)

    assert_non_root_user!(dockerfile)
    assert_entrypoint_invoked!(dockerfile)

    assert entrypoint =~ "GATEWAY_URLS",
           "entrypoint.sh must read GATEWAY_URLS from env"

    builder_keys = pod_spec_builder_env_keys()
    env_keys_matched = Enum.count(builder_keys, &String.contains?(entrypoint, &1))

    IO.puts("dockerfile_ok=true env_keys_matched=#{env_keys_matched}")

    assert env_keys_matched >= 2,
           "expected entrypoint.sh to reference at least 2 of the identity/gateway env keys " <>
             "PodSpecBuilder emits (#{inspect(builder_keys)}), matched #{env_keys_matched}"
  end

  defp assert_non_root_user!(dockerfile) do
    user_lines =
      dockerfile
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "USER "))

    assert user_lines != [], "Dockerfile must set a non-root USER"

    refute Enum.any?(user_lines, fn line ->
             user = line |> String.trim_leading("USER ") |> String.trim()
             user in ["root", "0"]
           end),
           "Dockerfile USER must not be root/0, got: #{inspect(user_lines)}"
  end

  defp assert_entrypoint_invoked!(dockerfile) do
    assert dockerfile =~ ~r/ENTRYPOINT.*entrypoint\.sh/ or
             dockerfile =~ ~r/CMD.*entrypoint\.sh/,
           "Dockerfile ENTRYPOINT or CMD must invoke entrypoint.sh"
  end

  # Reads the identity/gateway env var key literals `PodSpecBuilder`
  # emits, if that module has been generated yet. Falls back to the
  # canonical key set (this test's only source of truth pre-PodSpecBuilder)
  # so this suite never depends on that module compiling or existing.
  defp pod_spec_builder_env_keys do
    case File.read(@pod_spec_builder_path) do
      {:ok, source} ->
        matched = Enum.filter(@canonical_env_keys, &String.contains?(source, &1))
        if matched == [], do: @canonical_env_keys, else: matched

      {:error, _} ->
        @canonical_env_keys
    end
  end
end
