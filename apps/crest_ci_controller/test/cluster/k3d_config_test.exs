defmodule CrestCiController.Cluster.K3dConfigTest do
  @moduledoc """
  Verifies the k3d real-cluster bootstrap assets (deploy/k3d/cluster.yaml and
  the Makefile's k3d-* targets) without ever invoking docker or k3d.

  This is a static-shape test: it parses the cluster config YAML and greps
  the Makefile text. It never shells out to `k3d`/`docker`/`kubectl`, so it
  runs safely inside `mix test` on any machine, including CI, with no
  Docker daemon present.
  """

  use ExUnit.Case, async: true

  # apps/crest_ci_controller/test/cluster/k3d_config_test.exs -> repo root
  @project_root Path.expand("../../../..", __DIR__)
  @cluster_config_path Path.join([@project_root, "deploy", "k3d", "cluster.yaml"])
  @makefile_path Path.join(@project_root, "Makefile")

  @k3d_targets ["k3d-up", "k3d-load", "k3d-down", "k3d-status"]
  @gated_targets ["test", "check", "demo-e2e"]

  describe "deploy/k3d/cluster.yaml" do
    test "parses as YAML and declares a registry and at least one server node" do
      assert File.exists?(@cluster_config_path),
             "expected #{@cluster_config_path} to exist"

      assert {:ok, config} = YamlElixir.read_from_file(@cluster_config_path)

      assert config["apiVersion"] == "k3d.io/v1alpha5"
      assert config["kind"] == "Simple"

      servers = config["servers"]

      assert is_integer(servers) and servers >= 1,
             "expected at least one server node, got: #{inspect(servers)}"

      registry = get_in(config, ["registries", "create"])

      assert is_map(registry) and is_binary(registry["name"]) and registry["name"] != "",
             "expected registries.create.name to be set, got: #{inspect(config["registries"])}"
    end

    test "maps at least one host port so the gateway Service is reachable" do
      assert {:ok, config} = YamlElixir.read_from_file(@cluster_config_path)

      ports = config["ports"] || []

      assert is_list(ports) and ports != [],
             "expected at least one host port mapping under `ports:`"

      assert Enum.all?(ports, fn entry -> is_binary(entry["port"]) end),
             "every ports[] entry must declare a `port` host:container mapping"
    end
  end

  describe "Makefile k3d-* targets" do
    test "declares k3d-up/k3d-load/k3d-down/k3d-status and keeps them out of the test/check/demo-e2e gate" do
      assert File.exists?(@makefile_path), "expected #{@makefile_path} to exist"

      makefile = File.read!(@makefile_path)

      present_targets =
        Enum.filter(@k3d_targets, fn target ->
          Regex.match?(target_rule_regex(target), makefile)
        end)

      k3d_targets_count = length(present_targets)

      assert k3d_targets_count == length(@k3d_targets),
             "expected all of #{inspect(@k3d_targets)} to be defined as Makefile targets, " <>
               "found: #{inspect(present_targets)}"

      # gate_isolation: none of the k3d-* targets may appear as a
      # prerequisite on the same line as test/check/demo-e2e's target
      # declaration (i.e. `test: k3d-up` style coupling), and none of the
      # gated targets' recipe bodies may invoke `make k3d-*` / a bare k3d-*
      # target either.
      gate_isolation =
        not gated_target_depends_on_k3d?(makefile) and
          not gated_recipe_invokes_k3d?(makefile)

      IO.puts("k3d_targets=#{k3d_targets_count} gate_isolation=#{gate_isolation}")

      assert gate_isolation
    end
  end

  # Matches a Makefile target rule line, e.g. "k3d-up:" or "k3d-up: dep1 dep2".
  defp target_rule_regex(target) do
    Regex.compile!("^" <> Regex.escape(target) <> ":([^=]|$)", [:multiline])
  end

  # Returns true if any of test/check/demo-e2e's own target: line lists a
  # k3d-* target as a prerequisite.
  defp gated_target_depends_on_k3d?(makefile) do
    Enum.any?(@gated_targets, fn gated ->
      case Regex.run(
             Regex.compile!("^" <> Regex.escape(gated) <> ":(.*)$", [:multiline]),
             makefile
           ) do
        [_, prereqs] ->
          Enum.any?(@k3d_targets, fn k3d_target -> String.contains?(prereqs, k3d_target) end)

        nil ->
          false
      end
    end)
  end

  # Returns true if the recipe body (the indented lines following a
  # target: line, up to the next non-indented line) of any gated target
  # mentions a k3d-* target name, e.g. via `$(MAKE) k3d-up` or `make k3d-up`.
  defp gated_recipe_invokes_k3d?(makefile) do
    lines = String.split(makefile, "\n")

    @gated_targets
    |> Enum.any?(fn gated ->
      lines
      |> recipe_body_for(gated)
      |> Enum.any?(fn line -> Enum.any?(@k3d_targets, &String.contains?(line, &1)) end)
    end)
  end

  defp recipe_body_for(lines, target) do
    lines
    |> Enum.drop_while(
      &(not Regex.match?(Regex.compile!("^" <> Regex.escape(target) <> ":"), &1))
    )
    |> case do
      [] -> []
      [_target_line | rest] -> Enum.take_while(rest, &String.starts_with?(&1, "\t"))
    end
  end
end
