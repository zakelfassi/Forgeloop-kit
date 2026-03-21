defmodule ForgeloopV2.TestSupport do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias ForgeloopV2.{
        ActiveRuntime,
        BlockerDetector,
        Config,
        ControlFiles,
        ControlLock,
        Coordination,
        Daemon,
        Escalation,
        Events,
        FailureTracker,
        Orchestrator,
        WorkflowCatalog,
        WorkflowService,
        PathPolicy,
        PlanStore,
        RepoPaths,
        RuntimeLifecycle,
        RuntimeStateStore,
        Workspace
      }

      import ForgeloopV2.TestSupport
    end
  end

  def create_repo_fixture!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "forgeloop-v2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, ".forgeloop-test"))
    File.write!(Path.join(root, "REQUESTS.md"), Keyword.get(opts, :requests, ""))
    File.write!(Path.join(root, "QUESTIONS.md"), Keyword.get(opts, :questions, ""))
    File.write!(Path.join(root, "ESCALATIONS.md"), Keyword.get(opts, :escalations, ""))

    if Keyword.has_key?(opts, :plan_content) do
      File.write!(Path.join(root, "IMPLEMENTATION_PLAN.md"), Keyword.fetch!(opts, :plan_content))
    end

    on_exit(fn -> File.rm_rf(root) end)
    %{repo_root: root, runtime_dir: Path.join(root, ".forgeloop-test")}
  end

  def create_workflow_package!(repo_root, name, opts \\ []) do
    workflow_root = Keyword.get(opts, :workflow_root, Path.join(repo_root, "workflows"))
    package_root = Path.join(workflow_root, name)
    File.mkdir_p!(package_root)

    if Keyword.get(opts, :graph?, true) do
      File.write!(Path.join(package_root, "workflow.dot"), Keyword.get(opts, :graph_content, "digraph Test {}\n"))
    end

    if Keyword.get(opts, :config?, true) do
      File.write!(Path.join(package_root, "workflow.toml"), Keyword.get(opts, :config_content, "version = 1\n"))
    end

    if Keyword.get(opts, :prompts?, false) do
      File.mkdir_p!(Path.join(package_root, "prompts"))
    end

    if Keyword.get(opts, :scripts?, false) do
      File.mkdir_p!(Path.join(package_root, "scripts"))
    end

    package_root
  end

  def config_for!(repo_root, opts \\ []) do
    runtime_dir = Keyword.get(opts, :runtime_dir, Path.join(repo_root, ".forgeloop-test"))

    {:ok, config} =
      ForgeloopV2.Config.load(
        Keyword.merge(
          [
            repo_root: repo_root,
            runtime_dir: runtime_dir,
            shell_driver_enabled: false
          ],
          opts
        )
      )

    config
  end

  def wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  def write_executable!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  def with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(pairs, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  def now! do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "condition not met before timeout"
      end

      Process.sleep(10)
      do_wait_until(fun, deadline)
    end
  end
end
