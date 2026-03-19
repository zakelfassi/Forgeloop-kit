defmodule Mix.Tasks.ForgeloopV2.Loop do
  use Mix.Task

  alias ForgeloopV2.{Config, Loop}

  @shortdoc "Run one experimental Forgeloop v2 plan/build loop"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _invalid} =
      OptionParser.parse(args, strict: [repo: :string])

    mode =
      case argv do
        ["plan"] -> :plan
        ["build"] -> :build
        _ -> Mix.raise("usage: mix forgeloop_v2.loop [plan|build] [--repo PATH]")
      end

    config =
      case Config.load(repo_root: opts[:repo]) do
        {:ok, config} -> config
        {:error, reason} -> Mix.raise("failed to load config: #{inspect(reason)}")
      end

    case Loop.run(mode, config) do
      {:ok, _} -> :ok
      {:retry, count} -> Mix.raise("loop retry requested after failure count=#{count}")
      {:stopped, reason} -> Mix.raise("loop stopped: #{inspect(reason)}")
      {:error, reason} -> Mix.raise("loop failed: #{inspect(reason)}")
    end
  end
end
