defmodule Mix.Tasks.CrestCi.DemoK3dTest do
  @moduledoc """
  `asset.DemoK3d`'s only mix-gate validation: the real-cluster demo task
  compiles and exposes `run/1`, and the `demo-k3d` Makefile target it ships
  alongside stays isolated from the mix gate — `make test`/`make check`/
  `make demo-e2e` must never shell out to a real k3d cluster.

  This is a purely structural/static check: it never boots the task, never
  touches a kubeconfig, and never talks to any Kubernetes API — actually
  running `mix crest_ci.demo_k3d` requires a live k3d cluster
  (`make k3d-up`) and is a manual, out-of-gate operation (see the module's
  own `@moduledoc`).
  """

  use ExUnit.Case, async: true

  # apps/sim_runner/test/cluster/demo_k3d_test.exs -> repo root
  @project_root Path.expand("../../../..", __DIR__)
  @makefile_path Path.join(@project_root, "Makefile")

  @task_module Mix.Tasks.CrestCi.DemoK3d
  @gated_targets ["test", "check", "demo-e2e"]

  describe "mix crest_ci.demo_k3d task" do
    test "the task module compiles and exposes run/1" do
      assert {:module, @task_module} = Code.ensure_loaded(@task_module)

      assert function_exported?(@task_module, :run, 1),
             "expected #{inspect(@task_module)} to export run/1"

      compiles = true
      gated_out = gate_isolated?()

      IO.puts("demo_k3d_compiles=#{compiles} gated_out=#{gated_out}")

      assert compiles
      assert gated_out
    end
  end

  # -- Makefile gate isolation ------------------------------------------------

  defp gate_isolated? do
    assert_file_exists = File.exists?(@makefile_path)
    makefile = if assert_file_exists, do: File.read!(@makefile_path), else: ""

    declares_target = Regex.match?(~r/^demo-k3d:([^=]|$)/m, makefile)

    not_prerequisite = not gated_target_depends_on_demo_k3d?(makefile)
    not_invoked_by_recipe = not gated_recipe_invokes_demo_k3d?(makefile)

    assert_file_exists and declares_target and not_prerequisite and not_invoked_by_recipe
  end

  # Returns true if any of test/check/demo-e2e's own `target:` line lists
  # `demo-k3d` as a prerequisite (e.g. `test: demo-k3d`).
  defp gated_target_depends_on_demo_k3d?(makefile) do
    Enum.any?(@gated_targets, fn gated ->
      case Regex.run(~r/^#{Regex.escape(gated)}:(.*)$/m, makefile) do
        [_, prereqs] -> String.contains?(prereqs, "demo-k3d")
        nil -> false
      end
    end)
  end

  # Returns true if the recipe body (the tab-indented lines following a
  # `target:` line) of any gated target mentions `demo-k3d`, e.g. via
  # `$(MAKE) demo-k3d` or a bare `demo-k3d` invocation.
  defp gated_recipe_invokes_demo_k3d?(makefile) do
    lines = String.split(makefile, "\n")

    Enum.any?(@gated_targets, fn gated ->
      lines
      |> recipe_body_for(gated)
      |> Enum.any?(&String.contains?(&1, "demo-k3d"))
    end)
  end

  defp recipe_body_for(lines, target) do
    lines
    |> Enum.drop_while(&(not Regex.match?(~r/^#{Regex.escape(target)}:/, &1)))
    |> case do
      [] -> []
      [_target_line | rest] -> Enum.take_while(rest, &String.starts_with?(&1, "\t"))
    end
  end
end
