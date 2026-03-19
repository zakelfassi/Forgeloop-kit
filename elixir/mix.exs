defmodule ForgeloopV2.MixProject do
  use Mix.Project

  def project do
    [
      app: :forgeloop_v2,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: ["test/support/test_support.exs"],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ForgeloopV2.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
