defmodule Mix.Tasks.ForgeloopV2.Serve do
  use Mix.Task

  alias ForgeloopV2.{Config, Service}

  @shortdoc "Run the loopback-only control-plane service"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [repo: :string, host: :string, port: :integer]
      )

    config =
      case Config.load(repo_root: opts[:repo], service_host: opts[:host], service_port: opts[:port]) do
        {:ok, config} -> config
        {:error, reason} -> Mix.raise("failed to load config: #{inspect(reason)}")
      end

    {:ok, pid} =
      Service.start_link(
        config: config,
        host: opts[:host] || config.service_host,
        port: opts[:port] || config.service_port,
        name: nil,
        control_plane_name: nil
      )

    snapshot = Service.snapshot(pid)
    Mix.shell().info("Forgeloop v2 service listening on #{snapshot.base_url}")
    Process.sleep(:infinity)
  end
end
