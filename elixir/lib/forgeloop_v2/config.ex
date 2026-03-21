defmodule ForgeloopV2.RepoPaths do
  @moduledoc false

  @spec resolve(keyword()) :: {:ok, %{app_root: Path.t(), repo_root: Path.t(), forgeloop_root: Path.t()}} | {:error, term()}
  def resolve(opts \\ []) do
    cwd = Path.expand(Keyword.get(opts, :cwd, File.cwd!()))
    app_root = Path.expand(Keyword.get(opts, :app_root, cwd))

    explicit_repo_root =
      opts[:repo_root]
      |> normalize_optional_path(cwd)

    {repo_root, forgeloop_root} =
      case explicit_repo_root do
        nil -> infer_layout(app_root)
        repo_root -> {repo_root, infer_forgeloop_root(repo_root, app_root)}
      end

    with :ok <- require_dir(repo_root),
         :ok <- require_dir(forgeloop_root) do
      {:ok, %{app_root: app_root, repo_root: repo_root, forgeloop_root: forgeloop_root}}
    end
  end

  defp infer_layout(app_root) do
    app_root = Path.expand(app_root)

    cond do
      Path.basename(app_root) == "elixir" and Path.basename(Path.dirname(app_root)) == "forgeloop" ->
        forgeloop_root = Path.dirname(app_root)
        {Path.dirname(forgeloop_root), forgeloop_root}

      Path.basename(app_root) == "elixir" ->
        repo_root = Path.dirname(app_root)
        {repo_root, repo_root}

      true ->
        {app_root, infer_forgeloop_root(app_root, app_root)}
    end
  end

  defp infer_forgeloop_root(repo_root, app_root) do
    vendored_root = Path.join(repo_root, "forgeloop")

    cond do
      Path.basename(Path.dirname(app_root)) == "forgeloop" ->
        Path.dirname(app_root)

      File.exists?(Path.join(repo_root, "config.sh")) ->
        repo_root

      File.exists?(Path.join(vendored_root, "config.sh")) ->
        vendored_root

      true ->
        repo_root
    end
  end

  defp require_dir(path) do
    if File.dir?(path), do: :ok, else: {:error, {:missing_directory, path}}
  end

  defp normalize_optional_path(nil, _cwd), do: nil
  defp normalize_optional_path(path, cwd), do: Path.expand(path, cwd)
end

defmodule ForgeloopV2.Config do
  @moduledoc false

  @canonical_workflow_root "workflows"

  defstruct [
    :repo_root,
    :forgeloop_root,
    :runtime_dir,
    :runtime_state_file,
    :v2_state_dir,
    :requests_file,
    :questions_file,
    :escalations_file,
    :plan_file,
    :workflow_dir,
    :workflow_search_dirs,
    :workflow_runner,
    :default_branch,
    :control_lock_timeout_ms,
    :babysitter_heartbeat_interval_ms,
    :babysitter_shutdown_grace_ms,
    :service_host,
    :service_port,
    :failure_escalate_after,
    :failure_escalation_action,
    :max_blocked_iterations,
    :daemon_interval_seconds,
    :shell_driver_enabled,
    :loop_script,
    :plan_timeout_seconds,
    :build_timeout_seconds,
    :planning_model,
    :review_model,
    :security_model,
    :build_model,
    :enable_failover,
    :task_routing,
    :disable_claude,
    :disable_codex,
    :claude_cli,
    :claude_flags,
    :codex_cli,
    :codex_flags
  ]

  @type t :: %__MODULE__{}

  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, %{repo_root: repo_root, forgeloop_root: forgeloop_root}} <- ForgeloopV2.RepoPaths.resolve(opts) do
      shell_env = exported_shell_env(forgeloop_root, repo_root)

      runtime_dir =
        blank_to_nil(opts[:runtime_dir]) ||
          env_value("FORGELOOP_RUNTIME_DIR", shell_env) ||
          Path.join(repo_root, ".forgeloop")

      runtime_state_file =
        blank_to_nil(opts[:runtime_state_file]) ||
          env_value("FORGELOOP_RUNTIME_STATE_FILE", shell_env) ||
          Path.join(runtime_dir, "runtime-state.json")

      requests_path = repo_relative_path(repo_root, opts[:requests_file], "FORGELOOP_REQUESTS_FILE", "REQUESTS.md", shell_env)
      questions_path = repo_relative_path(repo_root, opts[:questions_file], "FORGELOOP_QUESTIONS_FILE", "QUESTIONS.md", shell_env)
      escalations_path = repo_relative_path(repo_root, opts[:escalations_file], "FORGELOOP_ESCALATIONS_FILE", "ESCALATIONS.md", shell_env)
      plan_path = repo_relative_path(repo_root, opts[:plan_file], "FORGELOOP_IMPLEMENTATION_PLAN_FILE", "IMPLEMENTATION_PLAN.md", shell_env)
      {workflow_dir, workflow_search_dirs} = detect_workflow_dirs(repo_root, opts[:workflow_dir], shell_env)
      loop_script = opts[:loop_script] || env_value("FORGELOOP_LOOP_SCRIPT", shell_env) || Path.join(forgeloop_root, "bin/loop.sh")

      config = %__MODULE__{
        repo_root: repo_root,
        forgeloop_root: forgeloop_root,
        runtime_dir: Path.expand(runtime_dir, repo_root),
        runtime_state_file: Path.expand(runtime_state_file, repo_root),
        v2_state_dir: Path.join(Path.expand(runtime_dir, repo_root), "v2"),
        requests_file: requests_path,
        questions_file: questions_path,
        escalations_file: escalations_path,
        plan_file: plan_path,
        workflow_dir: workflow_dir,
        workflow_search_dirs: workflow_search_dirs,
        workflow_runner: blank_to_nil(opts[:workflow_runner]) || env_value("FORGELOOP_WORKFLOW_RUNNER", shell_env),
        default_branch: opts[:default_branch] || env_value("FORGELOOP_DEFAULT_BRANCH", shell_env) || git_current_branch(repo_root) || "main",
        control_lock_timeout_ms: positive_int(opts[:control_lock_timeout_ms], "FORGELOOP_CONTROL_LOCK_TIMEOUT_MS", 2000, shell_env),
        babysitter_heartbeat_interval_ms:
          positive_int(opts[:babysitter_heartbeat_interval_ms], "FORGELOOP_BABYSITTER_HEARTBEAT_MS", 1000, shell_env),
        babysitter_shutdown_grace_ms:
          positive_int(opts[:babysitter_shutdown_grace_ms], "FORGELOOP_BABYSITTER_SHUTDOWN_GRACE_MS", 5000, shell_env),
        service_host:
          opts[:service_host] || env_value("FORGELOOP_SERVICE_HOST", shell_env) || "127.0.0.1",
        service_port:
          non_negative_int(opts[:service_port], "FORGELOOP_SERVICE_PORT", 4010, shell_env),
        failure_escalate_after: positive_int(opts[:failure_escalate_after], "FORGELOOP_FAILURE_ESCALATE_AFTER", 3, shell_env),
        failure_escalation_action: escalation_action(opts[:failure_escalation_action] || env_value("FORGELOOP_FAILURE_ESCALATION_ACTION", shell_env) || "issue"),
        max_blocked_iterations: positive_int(opts[:max_blocked_iterations], "FORGELOOP_MAX_BLOCKED_ITERATIONS", 3, shell_env),
        daemon_interval_seconds: positive_int(opts[:daemon_interval_seconds], "FORGELOOP_DAEMON_INTERVAL_SECONDS", 300, shell_env),
        shell_driver_enabled: truthy?(opts[:shell_driver_enabled], env_value("FORGELOOP_SHELL_DRIVER_ENABLED", shell_env), true),
        loop_script: loop_script,
        plan_timeout_seconds: positive_int(opts[:plan_timeout_seconds], "FORGELOOP_PLAN_TIMEOUT_SECONDS", 900, shell_env),
        build_timeout_seconds: positive_int(opts[:build_timeout_seconds], "FORGELOOP_LOOP_TIMEOUT_SECONDS", 3600, shell_env),
        planning_model: opts[:planning_model] || env_value("PLANNING_MODEL", shell_env) || "codex",
        review_model: opts[:review_model] || env_value("REVIEW_MODEL", shell_env) || "codex",
        security_model: opts[:security_model] || env_value("SECURITY_MODEL", shell_env) || "codex",
        build_model: opts[:build_model] || env_value("BUILD_MODEL", shell_env) || "claude",
        enable_failover: truthy?(opts[:enable_failover], env_value("ENABLE_FAILOVER", shell_env), true),
        task_routing: truthy?(opts[:task_routing], env_value("TASK_ROUTING", shell_env), true),
        disable_claude: truthy?(opts[:disable_claude], env_value("FORGELOOP_DISABLE_CLAUDE", shell_env), false),
        disable_codex: truthy?(opts[:disable_codex], env_value("FORGELOOP_DISABLE_CODEX", shell_env), false),
        claude_cli: opts[:claude_cli] || env_value("CLAUDE_CLI", shell_env) || "claude",
        claude_flags: opts[:claude_flags] || env_value("CLAUDE_FLAGS", shell_env) || "",
        codex_cli: opts[:codex_cli] || env_value("CODEX_CLI", shell_env) || "codex",
        codex_flags: opts[:codex_flags] || env_value("CODEX_FLAGS", shell_env) || ""
      }

      validate(config)
    end
  end

  defp validate(%__MODULE__{} = config) do
    cond do
      config.failure_escalation_action not in ~w(issue pr review rerun) ->
        {:error, {:invalid_escalation_action, config.failure_escalation_action}}

      config.shell_driver_enabled and not File.exists?(config.loop_script) ->
        {:error, {:missing_loop_script, config.loop_script}}

      true ->
        {:ok, config}
    end
  end

  defp repo_relative_path(repo_root, explicit, env_name, default, shell_env) do
    value = blank_to_nil(explicit) || env_value(env_name, shell_env) || default
    Path.expand(value, repo_root)
  end

  defp detect_workflow_dirs(repo_root, explicit, shell_env) do
    value = blank_to_nil(explicit) || env_value("FORGELOOP_WORKFLOWS_DIR", shell_env)

    cond do
      is_binary(value) and value != "" ->
        expanded = Path.expand(value, repo_root)
        {expanded, [expanded]}

      true ->
        canonical = workflow_root(repo_root, @canonical_workflow_root)
        {canonical, [canonical]}
    end
  end

  defp workflow_root(repo_root, relative_path), do: Path.join(repo_root, relative_path)

  defp positive_int(explicit, env_name, default, shell_env) do
    value = explicit || env_value(env_name, shell_env) || default

    case value do
      int when is_integer(int) and int > 0 -> int
      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int > 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp non_negative_int(explicit, env_name, default, shell_env) do
    value = explicit || env_value(env_name, shell_env) || default

    case value do
      int when is_integer(int) and int >= 0 -> int
      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int >= 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp truthy?(explicit, _env, _default) when is_boolean(explicit), do: explicit

  defp truthy?(nil, env, default) do
    case env do
      nil -> default
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  defp truthy?(value, _env, _default) when is_binary(value) do
    String.downcase(value) in ["1", "true", "yes", "on"]
  end

  defp escalation_action(value) when is_atom(value), do: value |> Atom.to_string() |> escalation_action()
  defp escalation_action(value) when is_binary(value), do: value |> String.downcase() |> String.trim()

  defp git_current_branch(repo_root) do
    case System.cmd("git", ["-C", repo_root, "branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> branch |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp env_value(name, shell_env) do
    (System.get_env(name) || Map.get(shell_env, name))
    |> blank_to_nil()
  end

  defp exported_shell_env(forgeloop_root, repo_root) do
    bash = System.find_executable("bash")
    config_file = Path.join(forgeloop_root, "config.sh")
    repo_env = Path.join(repo_root, ".env.local")

    cond do
      is_nil(bash) or not File.exists?(config_file) ->
        %{}

      true ->
        script = """
        source "$1" >/dev/null 2>&1 || true
        if [ -f "$2" ]; then
          source "$2" >/dev/null 2>&1 || true
        fi
        env -0
        """

        case System.cmd(bash, ["-lc", script, "--", config_file, repo_env], stderr_to_stdout: true) do
          {output, 0} -> parse_null_env(output)
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  defp parse_null_env(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end
end
