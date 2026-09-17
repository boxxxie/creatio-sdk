defmodule Creatio.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://gitlab.nvestiv.com/caasa/creatio-sdk"

  def project do
    [
      app: :creatio,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 84]],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, ">= 0.5.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir SDK for the Creatio CRM API, supporting OData 4, OData 3, OAuth 2.0, and Forms authentication."
  end

  defp package do
    [
      name: "creatio",
      maintainers: ["CAASA"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitLab" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
