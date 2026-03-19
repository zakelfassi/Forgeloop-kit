defmodule Mix.Tasks.ForgeloopV2.Daemon do
  use Mix.Task

  alias ForgeloopV2.{Config, Daemon}

  @shortdoc "Run the experimental Forgeloop v2 daemon"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [repo: :string, interval: :integer, driver: :string, once: :boolean]
      )

    config =
      case Config.load(repo_root: opts[:repo]) do
        {:ok, config} -> config
        {:error, reason} -> Mix.raise("failed to load config: #{inspect(reason)}")
      end

    driver = driver_module(opts[:driver] || "shell")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: driver,
        schedule: !opts[:once],
        interval_ms: (opts[:interval] || config.daemon_interval_seconds) * 1_000
      )

    if opts[:once] do
      Daemon.run_once(pid)
      wait_until_idle(pid)
    else
      Process.sleep(:infinity)
    end
  end

  defp driver_module("noop"), do: ForgeloopV2.WorkDrivers.Noop
  defp driver_module(_), do: ForgeloopV2.WorkDrivers.ShellLoop

  defp wait_until_idle(pid) do
    if Daemon.snapshot(pid).running? do
      Process.sleep(20)
      wait_until_idle(pid)
    else
      :ok
    end
  end
end
