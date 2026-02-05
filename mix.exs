defmodule ScenicDriverRemote.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/user/scenic_driver_remote"

  def project do
    [
      app: :scenic_driver_remote,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Transport-agnostic Scenic driver for remote rendering",
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
      {:scenic, "~> 0.11"},
      {:nimble_options, "~> 1.0"},
      # Optional transports
      {:websockex, "~> 0.4", optional: true},
      # Dev/test
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
