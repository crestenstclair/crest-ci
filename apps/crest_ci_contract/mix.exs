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
  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
