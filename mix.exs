defmodule Creatio.MixProject do
  use Mix.Project

  @version "1.0.1"
  @source_url "https://github.com/boxxxie/creatio-sdk"

  def project do
    [
      app: :creatio,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [threshold: 84],
        ignore_modules: [
          Creatio.FeatureScenario,
          Creatio.LiveHelper,
          ~r/^Creatio\.TestDSL\./,
          ~r/^Creatio\.TestDrivers\./
        ]
      ],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5 or ~> 0.6 or ~> 0.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
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
      maintainers: ["Paul Iannazzo"],
      files:
        ~w(lib docs/CREATIO_API_INTEGRATION.md docs/USE_CASES_SYNCING_USERS.md .formatter.exs mix.exs README.md CHANGELOG.md LICENSE usage-rules.md),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "usage-rules.md",
        "docs/CREATIO_API_INTEGRATION.md",
        "docs/USE_CASES_SYNCING_USERS.md",
        "LICENSE"
      ]
    ]
  end
end
