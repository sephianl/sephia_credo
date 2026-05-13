defmodule SephiaCredo.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "Credo checks for common Elixir pitfalls"
  @github_url "https://github.com/sephianl/sephia_credo"

  def project do
    [
      app: :sephia_credo,
      version: @version,
      description: @description,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: docs(),
      source_url: @github_url,
      homepage_url: @github_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib/", "test/support/"]
  defp elixirc_paths(_), do: ["lib/"]

  defp deps do
    [
      {:credo, "~> 1.7"},
      {:igniter, "~> 0.7", optional: true},
      {:ex_check, "~> 0.16", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      links: %{"GitHub" => @github_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
