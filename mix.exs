defmodule Bildad.MixProject do
  use Mix.Project

  def project do
    [
      app: :bildad,
      version: "0.1.13",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Bildad",
      source_url: "https://github.com/Cobenian/bildad",
      docs: [
        main: "Bildad",
        extras: ["README.md", "CHANGELOG.md"],
        authors: ["Bryan Weber", "Bryan Tylor"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Bildad.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_json_schema, "~> 0.11.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.12"},
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:myxql, "~> 0.7", only: :test},
      {:jason, "~> 1.4", only: :test}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp description() do
    """
    Bildad is a job scheduling framework for Phoenix applications (works with LiveView). It is designed to be simple to use and easy to integrate into your existing Elixir applications.
    """
  end

  defp package() do
    [
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Cobenian/bildad"}
    ]
  end
end
