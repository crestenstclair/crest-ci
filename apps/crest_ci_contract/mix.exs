defmodule CrestCiContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :crest_ci_contract,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" for examples and options.
  #
  # plug/bandit are test-only: they back
  # `CrestCiContract.Test.FakeKubeHttpServer`, an in-repo HTTP fixture used
  # to exercise `CrestCiContract.ReqKubeClient` over real HTTP. They are
  # not a dependency on `mock_k8s` itself, which would create a cyclic
  # umbrella dependency (`mock_k8s` already depends on this app).
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test}
    ]
  end
end
