defmodule Mix.Tasks.ForgeloopV2.Workflow do
  use Mix.Task

  alias ForgeloopV2.{Config, ControlPlane, WorkflowCatalog}

  @shortdoc "Run native workflow packs through the managed babysitter path"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, _invalid} =
      OptionParser.parse(args,
        strict: [repo: :string, branch: :string]
      )

    repo_root =
      case opts[:repo] do
        nil -> nil
        path -> canonical_repo_root(path)
      end

    config =
      case Config.load(repo_root: repo_root) do
        {:ok, config} -> config
        {:error, reason} -> Mix.raise("failed to load config: #{inspect(reason)}")
      end

    case argv do
      ["list"] ->
        WorkflowCatalog.list(config)
        |> Enum.each(&Mix.shell().info(&1.name))

      ["preflight", workflow_name] ->
        run_managed_workflow(config, workflow_name, :preflight, opts, [])

      ["run", workflow_name | runner_args] ->
        run_managed_workflow(config, workflow_name, :run, opts, runner_args)

      _ ->
        Mix.raise("usage: mix forgeloop_v2.workflow [list|preflight <name>|run <name> [-- extra args...]] [--repo PATH] [--branch NAME]")
    end
  end

  defp run_managed_workflow(config, workflow_name, action, opts, runner_args) do
    {:ok, pid} =
      ControlPlane.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        name: nil
      )

    case ControlPlane.start_workflow(pid, workflow_name, action,
           branch: opts[:branch],
           runtime_surface: "workflow",
           runner_args: runner_args
         ) do
      {:ok, _payload} -> :ok
      {:error, reason} -> Mix.raise("workflow failed to start: #{inspect(reason)}")
    end

    wait_until_idle(pid)

    output =
      case ControlPlane.workflow_fetch(pid, workflow_name, include_output?: true) do
        {:ok, summary} -> output_for_action(summary, action)
        :missing -> nil
        {:error, _reason} -> nil
      end

    if is_binary(output) and output != "" do
      IO.write(output)
    end

    case ControlPlane.babysitter(pid) do
      {:ok, %{snapshot: %{last_result: {:ok, _payload}}}} -> :ok
      {:ok, %{snapshot: %{last_result: {:retry, count}}}} -> Mix.raise("workflow requested retry after failure count=#{count}")
      {:ok, %{snapshot: %{last_result: {:stopped, reason}}}} -> Mix.raise("workflow stopped: #{inspect(reason)}")
      {:ok, %{snapshot: %{last_result: {:error, reason}}}} -> Mix.raise("workflow failed: #{inspect(reason)}")
      {:ok, %{snapshot: %{last_result: other}}} -> Mix.raise("workflow completed with unexpected result: #{inspect(other)}")
      {:error, reason} -> Mix.raise("failed to read babysitter result: #{inspect(reason)}")
    end
  end

  defp output_for_action(summary, :preflight), do: summary.preflight.output
  defp output_for_action(summary, :run), do: summary.run.output

  defp canonical_repo_root(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {resolved, 0} -> String.trim(resolved)
      _ -> Path.expand(path)
    end
  end

  defp wait_until_idle(pid) do
    case ControlPlane.babysitter(pid) do
      {:ok, %{running?: true}} ->
        Process.sleep(20)
        wait_until_idle(pid)

      {:ok, _payload} ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to poll babysitter: #{inspect(reason)}")
    end
  end
end
