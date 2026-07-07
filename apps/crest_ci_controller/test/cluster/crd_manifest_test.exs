defmodule CrestCiController.Cluster.CrdManifestTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Parses every `deploy/crds/*.yaml` CustomResourceDefinition manifest and
  asserts each is a well-formed `apiextensions.k8s.io/v1`
  `CustomResourceDefinition` for group `ci.crest.dev`, declares a `status`
  subresource, and that its declared plural/kind match the
  `CrestCiContract` naming this bounded context uses elsewhere
  (`WorkflowRun`/`workflowruns`, `RunnerJob`/`runnerjobs`,
  `RunnerPool`/`runnerpools`, `WorkflowDefinition`/`workflowdefinitions` —
  see `MockK8s.KubeApiHttp.Kinds`).
  """

  @crds_dir Path.expand("../../../../deploy/crds", __DIR__)

  @expected_kinds %{
    "workflowrun.yaml" => {"WorkflowRun", "workflowruns"},
    "runnerjob.yaml" => {"RunnerJob", "runnerjobs"},
    "runnerpool.yaml" => {"RunnerPool", "runnerpools"},
    "workflowdefinition.yaml" => {"WorkflowDefinition", "workflowdefinitions"}
  }

  describe "deploy/crds/*.yaml" do
    test "every expected CRD file exists" do
      for {filename, _} <- @expected_kinds do
        path = Path.join(@crds_dir, filename)
        assert File.exists?(path), "expected CRD manifest at #{path}"
      end
    end

    test "each manifest is a well-formed CustomResourceDefinition for group ci.crest.dev with a status subresource, and the count of parsed CRDs matches the count declaring a status subresource (>= 4)" do
      results =
        for {filename, {expected_kind, expected_plural}} <- @expected_kinds do
          path = Path.join(@crds_dir, filename)
          {:ok, manifest} = YamlElixir.read_from_file(path)

          assert manifest["apiVersion"] == "apiextensions.k8s.io/v1",
                 "#{filename}: expected apiVersion apiextensions.k8s.io/v1"

          assert manifest["kind"] == "CustomResourceDefinition",
                 "#{filename}: expected kind CustomResourceDefinition"

          spec = manifest["spec"]
          assert spec["group"] == "ci.crest.dev", "#{filename}: expected group ci.crest.dev"

          names = spec["names"]

          assert names["kind"] == expected_kind,
                 "#{filename}: expected names.kind #{expected_kind}, got #{inspect(names["kind"])}"

          assert names["plural"] == expected_plural,
                 "#{filename}: expected names.plural #{expected_plural}, got #{inspect(names["plural"])}"

          versions = spec["versions"] || []
          assert versions != [], "#{filename}: expected at least one version"

          has_status_subresource? =
            Enum.any?(versions, fn version ->
              is_map(version["subresources"]) and Map.has_key?(version["subresources"], "status")
            end)

          assert has_status_subresource?,
                 "#{filename}: expected a status subresource declared on at least one version"

          has_status_subresource?
        end

      crds = length(results)
      with_status = Enum.count(results, & &1)

      IO.puts("crds=#{crds} with_status=#{with_status}")

      assert crds == with_status
      assert crds >= 4
    end
  end
end
