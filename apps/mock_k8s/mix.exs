defmodule MockK8s.MixProject do
  use Mix.Project

  def project do
    [
      app: :mock_k8s,
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
  #
  # No mod: entry — this app exposes explicit start functions for its
  # HTTP server; it must not bind a port automatically at boot.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:crest_ci_contract, in_umbrella: true}
    ]
  end
end
