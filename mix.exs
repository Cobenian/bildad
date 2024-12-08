defmodule Bildad.MixProject do
  use Mix.Project

  def project do
    [
      app: :bildad,
      version: "0.1.8",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_json_schema, "~> 0.10.2"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.6"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
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
