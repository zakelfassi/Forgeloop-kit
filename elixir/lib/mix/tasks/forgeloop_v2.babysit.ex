defmodule Mix.Tasks.ForgeloopV2.Babysit do
  use Mix.Task

  alias ForgeloopV2.{Babysitter, Config}

  @shortdoc "Run one manual disposable-worktree babysitter cycle"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _invalid} =
      OptionParser.parse(args,
        strict: [repo: :string, driver: :string, branch: :string]
      )

    mode =
      case argv do
        ["plan"] -> :plan
        ["build"] -> :build
        _ -> Mix.raise("usage: mix forgeloop_v2.babysit [plan|build] [--repo PATH] [--driver noop|shell] [--branch NAME]")
      end

    config =
      case Config.load(repo_root: opts[:repo]) do
        {:ok, config} -> config
        {:error, reason} -> Mix.raise("failed to load config: #{inspect(reason)}")
      end

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: mode,
        branch: opts[:branch] || config.default_branch,
        driver: driver_module(opts[:driver] || if(config.shell_driver_enabled, do: "shell", else: "noop"))
      )

    result =
      case Babysitter.start_run(pid) do
        :ok -> Babysitter.await_result(pid, stop?: true)
        {:error, reason} -> Mix.raise("babysitter failed to start: #{inspect(reason)}")
      end

    case result do
      {:ok, _payload} -> :ok
      {:retry, count} -> Mix.raise("babysitter child requested retry after failure count=#{count}")
      {:stopped, reason} -> Mix.raise("babysitter child stopped: #{inspect(reason)}")
      {:error, reason} -> Mix.raise("babysitter child failed: #{inspect(reason)}")
      other -> Mix.raise("babysitter completed with unexpected result: #{inspect(other)}")
    end
  end

  defp driver_module("noop"), do: ForgeloopV2.WorkDrivers.Noop
  defp driver_module(_), do: ForgeloopV2.WorkDrivers.ShellLoop
end
