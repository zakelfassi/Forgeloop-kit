defmodule ForgeloopV2.WorkDriver do
  @moduledoc false

  alias ForgeloopV2.{Config, RunSpec}

  @callback run(RunSpec.t() | :plan | :build, Config.t(), keyword()) ::
              {:ok, %{mode: atom() | String.t(), evidence_file: Path.t() | nil}}
              | {:error, %{kind: String.t(), summary: String.t(), evidence_file: Path.t() | nil}}
end

defmodule ForgeloopV2.WorkDrivers.Noop do
  @moduledoc false
  @behaviour ForgeloopV2.WorkDriver

  alias ForgeloopV2.RunSpec

  @impl true
  def run(mode_or_spec, _config, opts) do
    spec = normalize_spec!(mode_or_spec)
    scenario = scenario_for(opts, spec)

    result =
      cond do
        is_function(scenario, 1) -> scenario.(spec)
        true -> scenario
      end

    case result do
      {:ok, payload} when is_map(payload) ->
        {:ok, Map.put_new(payload, :mode, payload_mode(spec)) |> Map.put_new(:evidence_file, nil)}

      {:error, payload} when is_map(payload) ->
        {:error,
         payload
         |> Map.put_new(:kind, RunSpec.runtime_mode(spec))
         |> Map.put_new(:summary, "#{RunSpec.runtime_mode(spec)} failed")
         |> Map.put_new(:evidence_file, nil)}

      _ ->
        {:ok, %{mode: payload_mode(spec), evidence_file: nil}}
    end
  end

  defp scenario_for(opts, %RunSpec{lane: :workflow, action: action}) do
    Keyword.get(opts, String.to_atom("workflow_#{action}")) ||
      Keyword.get(opts, action) ||
      Keyword.get(opts, :result, {:ok, %{}})
  end

  defp scenario_for(opts, %RunSpec{action: action}) do
    Keyword.get(opts, action) || Keyword.get(opts, :result, {:ok, %{}})
  end

  defp payload_mode(%RunSpec{lane: :workflow} = spec), do: RunSpec.runtime_mode(spec)
  defp payload_mode(%RunSpec{action: action}), do: action

  defp normalize_spec!(%RunSpec{} = spec), do: spec

  defp normalize_spec!(mode) do
    case RunSpec.checklist(mode) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid noop run mode: #{inspect(reason)}"
    end
  end
end

defmodule ForgeloopV2.WorkDrivers.ShellLoop do
  @moduledoc false
  @behaviour ForgeloopV2.WorkDriver

  alias ForgeloopV2.{Config, RunSpec, WorkflowCatalog, Worktree}
  alias ForgeloopV2.WorkflowCatalog.Entry

  @impl true
  def run(mode_or_spec, %Config{} = config, opts) do
    spec = normalize_spec!(mode_or_spec)

    case spec.lane do
      :checklist -> run_checklist(spec, config, opts)
      :workflow -> run_workflow(spec, config, opts)
    end
  end

  defp run_checklist(%RunSpec{action: mode}, %Config{} = config, opts) do
    File.mkdir_p!(Path.join(config.v2_state_dir, "driver"))
    evidence_file = Path.join([config.v2_state_dir, "driver", "#{mode}-last.txt"])
    args = loop_args(mode, Keyword.get(opts, :iterations, 10))
    timeout_ms = timeout_ms(mode, config)
    worktree = Keyword.get(opts, :worktree)
    {cmd_path, cmd_opts} = shell_command_opts(config, worktree, opts)

    case run_command(cmd_path, args, cmd_opts, timeout_ms) do
      {:timeout, output} ->
        File.write!(evidence_file, output <> "#{mode} command timed out\n")
        {:error, %{kind: "timeout", summary: "#{mode} command timed out", evidence_file: evidence_file}}

      {output, 0} ->
        File.write!(evidence_file, output)
        {:ok, %{mode: mode, evidence_file: evidence_file}}

      {output, _status} ->
        File.write!(evidence_file, output)
        {:error, %{kind: Atom.to_string(mode), summary: "#{mode} command failed", evidence_file: evidence_file}}
    end
  end

  defp run_workflow(%RunSpec{} = spec, %Config{} = config, opts) do
    artifact_path = workflow_artifact_path(config, spec.workflow_name, spec.action)
    File.mkdir_p!(Path.dirname(artifact_path))

    with {:ok, %Entry{} = entry} <- fetch_workflow_entry(config, spec.workflow_name),
         {:ok, package_dir} <- workflow_package_dir(config, entry, Keyword.get(opts, :worktree)),
         {:ok, runner_path} <- resolve_workflow_runner(config) do
      cmd_opts = [cd: package_dir, env: workflow_env(config, opts, spec)]
      args = workflow_args(spec, Keyword.get(opts, :runner_args, []))

      case run_command(runner_path, args, cmd_opts, :infinity) do
        {:timeout, output} ->
          File.write!(artifact_path, output <> "#{RunSpec.runtime_mode(spec)} command timed out\n")
          {:error,
           %{kind: "timeout", summary: "#{RunSpec.runtime_mode(spec)} command timed out", evidence_file: artifact_path}}

        {output, 0} ->
          File.write!(artifact_path, output)
          {:ok, %{mode: RunSpec.runtime_mode(spec), evidence_file: artifact_path}}

        {output, _status} ->
          File.write!(artifact_path, output)

          {:error,
           %{
             kind: RunSpec.runtime_mode(spec),
             summary: "#{RunSpec.runtime_mode(spec)} command failed",
             evidence_file: artifact_path
           }}
      end
    else
      {:error, :workflow_runner_not_found} ->
        message = "workflow runner not found\nSet FORGELOOP_WORKFLOW_RUNNER or install forgeloop-workflow.\n"
        File.write!(artifact_path, message)

        {:error,
         %{
           kind: RunSpec.runtime_mode(spec),
           summary: "workflow runner not found",
           evidence_file: artifact_path
         }}

      {:error, {:invalid_workflow_name, _} = reason} ->
        File.write!(artifact_path, "#{inspect(reason)}\n")
        {:error, %{kind: RunSpec.runtime_mode(spec), summary: inspect(reason), evidence_file: artifact_path}}

      :missing ->
        File.write!(artifact_path, "workflow not found: #{spec.workflow_name}\n")
        {:error, %{kind: RunSpec.runtime_mode(spec), summary: "workflow not found", evidence_file: artifact_path}}

      {:error, reason} ->
        File.write!(artifact_path, "#{inspect(reason)}\n")
        {:error, %{kind: RunSpec.runtime_mode(spec), summary: inspect(reason), evidence_file: artifact_path}}
    end
  end

  defp fetch_workflow_entry(%Config{} = config, workflow_name) do
    WorkflowCatalog.fetch(config, workflow_name)
  end

  defp workflow_package_dir(_config, %Entry{root: root}, nil), do: {:ok, root}

  defp workflow_package_dir(%Config{} = config, %Entry{root: root}, %Worktree.Handle{} = worktree) do
    relative = Path.relative_to(Path.expand(root), config.repo_root)

    cond do
      relative == Path.expand(root) -> {:error, {:workflow_root_outside_repo, root, config.repo_root}}
      String.starts_with?(relative, "../") -> {:error, {:workflow_root_outside_repo, root, config.repo_root}}
      true -> {:ok, Path.join(worktree.checkout_path, relative)}
    end
  end

  defp resolve_workflow_runner(%Config{} = config) do
    configured = config.workflow_runner

    cond do
      is_binary(configured) and configured != "" and String.contains?(configured, "/") ->
        expanded = Path.expand(configured, config.repo_root)
        if File.exists?(expanded), do: {:ok, expanded}, else: {:error, :workflow_runner_not_found}

      is_binary(configured) and configured != "" ->
        case System.find_executable(configured) do
          nil -> {:error, :workflow_runner_not_found}
          path -> {:ok, path}
        end

      true ->
        case System.find_executable("forgeloop-workflow") do
          nil -> {:error, :workflow_runner_not_found}
          path -> {:ok, path}
        end
    end
  end

  defp workflow_args(%RunSpec{action: :preflight, workflow_name: workflow_name}, runner_args) do
    ["run", "--preflight", workflow_name | Enum.map(runner_args, &to_string/1)]
  end

  defp workflow_args(%RunSpec{action: :run, workflow_name: workflow_name}, runner_args) do
    ["run", workflow_name | Enum.map(runner_args, &to_string/1)]
  end

  defp workflow_env(%Config{} = config, opts, %RunSpec{workflow_name: workflow_name}) do
    canonical_env(config, opts) ++
      [
        {"FORGELOOP_WORKFLOW_STATE_ROOT", Path.join([config.runtime_dir, "workflows", "state"])},
        {"FORGELOOP_WORKFLOW_NAME", workflow_name}
      ]
  end

  defp workflow_artifact_path(%Config{} = config, workflow_name, :preflight) do
    Path.join([config.runtime_dir, "workflows", workflow_name, "last-preflight.txt"])
  end

  defp workflow_artifact_path(%Config{} = config, workflow_name, :run) do
    Path.join([config.runtime_dir, "workflows", workflow_name, "last-run.txt"])
  end

  defp loop_args(:plan, _iterations), do: ["plan", "1"]
  defp loop_args(:build, iterations), do: [to_string(iterations)]
  defp timeout_ms(:plan, config), do: config.plan_timeout_seconds * 1_000
  defp timeout_ms(:build, config), do: config.build_timeout_seconds * 1_000

  defp shell_command_opts(%Config{} = config, nil, _opts) do
    {config.loop_script, [cd: config.repo_root, env: []]}
  end

  defp shell_command_opts(%Config{} = config, %Worktree.Handle{} = worktree, opts) do
    {worktree.loop_script_path,
     [
       cd: worktree.checkout_path,
       env: canonical_env(config, opts)
     ]}
  end

  defp canonical_env(%Config{} = config, opts) do
    [
      {"FORGELOOP_RUNTIME_DIR", config.runtime_dir},
      {"FORGELOOP_RUNTIME_STATE_FILE", config.runtime_state_file},
      {"FORGELOOP_REQUESTS_FILE", config.requests_file},
      {"FORGELOOP_QUESTIONS_FILE", config.questions_file},
      {"FORGELOOP_ESCALATIONS_FILE", config.escalations_file},
      {"FORGELOOP_IMPLEMENTATION_PLAN_FILE", config.plan_file},
      {"FORGELOOP_RUNTIME_BRANCH", to_string(Keyword.get(opts, :runtime_branch, config.default_branch))},
      {"FORGELOOP_RUNTIME_SURFACE", to_string(Keyword.get(opts, :runtime_surface, "loop"))},
      {"FORGELOOP_RUNTIME_MODE", to_string(Keyword.get(opts, :runtime_mode, "build"))}
    ]
  end

  defp run_command(cmd_path, args, cmd_opts, timeout_ms) do
    port =
      Port.open({:spawn_executable, String.to_charlist(cmd_path)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(args, &String.to_charlist/1)},
        {:cd, String.to_charlist(Keyword.fetch!(cmd_opts, :cd))},
        {:env,
         cmd_opts
         |> Keyword.get(:env, [])
         |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)}
      ])

    collect_port_output(port, "", timeout_ms)
  rescue
    error in ErlangError ->
      case Map.get(error, :original) do
        :enoent -> {"command not found: #{cmd_path}", 127}
        _ -> reraise(error, __STACKTRACE__)
      end
  end

  defp collect_port_output(port, output, :infinity) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port_output(port, output <> chunk, :infinity)

      {^port, {:exit_status, status}} ->
        {output, status}
    end
  end

  defp collect_port_output(port, output, timeout_ms) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port_output(port, output <> chunk, timeout_ms)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      timeout_ms ->
        _ = safe_close_port(port)
        {:timeout, output}
    end
  end

  defp safe_close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp normalize_spec!(%RunSpec{} = spec), do: spec

  defp normalize_spec!(mode) do
    case RunSpec.checklist(mode) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid shell run mode: #{inspect(reason)}"
    end
  end
end

defmodule ForgeloopV2.Loop do
  @moduledoc false

  alias ForgeloopV2.{
    ActiveRuntime,
    Config,
    ControlFiles,
    FailureTracker,
    RunSpec,
    RuntimeLifecycle,
    RuntimeRecovery,
    RuntimeState,
    RuntimeStateStore,
    Workspace
  }

  @spec run(RunSpec.t() | :plan | :build, Config.t(), keyword()) ::
          {:ok, map()} | {:retry, pos_integer()} | {:stopped, term()} | {:error, term()}
  def run(mode_or_spec, %Config{} = config, opts \\ []) do
    with {:ok, run_spec} <- normalize_run_spec(mode_or_spec) do
      surface = Keyword.get(opts, :surface, default_surface(run_spec, opts))
      runtime_mode = Keyword.get(opts, :runtime_mode, RunSpec.runtime_mode(run_spec))
      driver = Keyword.get(opts, :driver, default_driver(config, run_spec))
      driver_opts =
        opts
        |> Keyword.get(:driver_opts, [])
        |> Keyword.put_new(:runtime_branch, Keyword.get(opts, :branch, config.default_branch))
        |> Keyword.put_new(:runtime_surface, surface)
        |> Keyword.put_new(:runtime_mode, runtime_mode)
      
      requested_action =
        Keyword.get(opts, :requested_action, RunSpec.requested_action(run_spec, config.failure_escalation_action))
      branch = Keyword.get(opts, :branch, config.default_branch)
      prior_status = RuntimeStateStore.status(config)
      unanswered_question_ids = ControlFiles.unanswered_question_ids(config)
      writer = writer_for(surface)

      with :ok <- ActiveRuntime.claim(config, "elixir"),
           {:ok, workspace} <-
             Workspace.from_config(
               config,
               branch: branch,
               mode: runtime_mode,
               kind: RunSpec.workspace_kind(run_spec)
             ),
           {:ok, _state} <-
             maybe_write_recovered(
               config,
               prior_status,
               unanswered_question_ids,
               writer,
               surface,
               runtime_mode,
               branch,
               run_spec
             ),
           {:ok, _state} <-
             RuntimeLifecycle.transition(config, :loop_started, writer, %{
               surface: surface,
               mode: runtime_mode,
               reason: started_reason(run_spec),
               requested_action: requested_action,
               branch: branch
             }) do
        case driver.run(run_spec, config, driver_opts) do
          {:ok, payload} ->
            :ok = FailureTracker.clear(config)

            {:ok, _state} =
              RuntimeLifecycle.transition(config, :loop_completed, writer, %{
                surface: surface,
                mode: runtime_mode,
                reason: completed_reason(run_spec),
                requested_action: "",
                branch: branch
              })

            {:ok, Map.merge(payload, Workspace.metadata(workspace))}

          {:error, %{kind: kind, summary: summary, evidence_file: evidence_file}} ->
            if already_escalated?(config) do
              {:stopped, :already_escalated}
            else
              case FailureTracker.handle(config, %{
                     kind: kind,
                     summary: summary,
                     evidence_file: evidence_file,
                     requested_action: requested_action,
                     surface: surface,
                     mode: runtime_mode,
                     branch: branch
                   }) do
                {:retry, count} -> {:retry, count}
                {:stop, count} -> {:stopped, {:escalated, count}}
                {:error, reason} -> {:error, reason}
              end
            end
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_run_spec(%RunSpec{} = spec), do: {:ok, spec}
  defp normalize_run_spec(mode), do: RunSpec.checklist(mode)

  defp default_surface(%RunSpec{lane: :workflow}, opts), do: Keyword.get(opts, :surface, "workflow")
  defp default_surface(_spec, opts), do: Keyword.get(opts, :surface, "loop")

  defp started_reason(%RunSpec{lane: :checklist, action: :plan}), do: "Planning run started"
  defp started_reason(%RunSpec{lane: :checklist, action: :build}), do: "Build run started"
  defp started_reason(%RunSpec{lane: :workflow, action: :preflight, workflow_name: name}), do: "Workflow preflight started: #{name}"
  defp started_reason(%RunSpec{lane: :workflow, action: :run, workflow_name: name}), do: "Workflow run started: #{name}"

  defp completed_reason(%RunSpec{lane: :workflow, action: action, workflow_name: name}) do
    "workflow #{action} completed for #{name}"
  end

  defp completed_reason(%RunSpec{action: action}), do: "#{action} completed"

  defp default_driver(_config, %RunSpec{lane: :workflow}), do: ForgeloopV2.WorkDrivers.ShellLoop

  defp default_driver(config, _run_spec) do
    if config.shell_driver_enabled do
      ForgeloopV2.WorkDrivers.ShellLoop
    else
      ForgeloopV2.WorkDrivers.Noop
    end
  end

  defp already_escalated?(config) do
    ControlFiles.has_flag?(config, "PAUSE") or RuntimeStateStore.status(config) == "awaiting-human"
  end

  defp maybe_write_recovered(
         config,
         prior_status,
         unanswered_question_ids,
         writer,
         surface,
         runtime_mode,
         branch,
         run_spec
       ) do
    case RuntimeRecovery.evaluate(prior_status, unanswered_question_ids, allow_blocked?: true) do
      {:recover, kind} ->
        RuntimeLifecycle.transition(config, :recovered, writer, %{
          surface: surface,
          mode: runtime_mode,
          reason: recovery_reason(kind, RunSpec.runtime_mode(run_spec)),
          requested_action: "",
          branch: branch
        })

      :no_recovery ->
        {:ok, %RuntimeState{}}
    end
  end

  defp recovery_reason(:blocked, mode), do: "Resuming #{mode} after clearing blocked state"
  defp recovery_reason(:paused, mode), do: "Resuming #{mode} after clearing paused state"
  defp recovery_reason(:awaiting_human_cleared, mode),
    do: "Resuming #{mode} after clearing awaiting-human state"

  defp writer_for("daemon"), do: :daemon
  defp writer_for("babysitter"), do: :babysitter
  defp writer_for(_surface), do: :loop
end

defmodule ForgeloopV2.Daemon.State do
  @moduledoc false
  defstruct [
    :config,
    :driver,
    :driver_opts,
    :interval_ms,
    :timer_ref,
    :current_task_ref,
    :current_task_kind,
    :running?,
    :last_result,
    :last_action,
    schedule?: true
  ]
end

defmodule ForgeloopV2.Daemon do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    ActiveRuntime,
    Babysitter,
    Config,
    ControlFiles,
    ControlLock,
    Daemon.State,
    Escalation,
    Events,
    FailureTracker,
    Orchestrator,
    RunSpec,
    RuntimeLifecycle,
    RuntimeStateStore,
    Worktree
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec run_once(GenServer.server()) :: :ok
  def run_once(server \\ __MODULE__) do
    GenServer.cast(server, :run_once)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        state = %State{
          config: config,
          driver: Keyword.get(opts, :driver, ForgeloopV2.WorkDrivers.Noop),
          driver_opts: Keyword.get(opts, :driver_opts, []),
          interval_ms: Keyword.get(opts, :interval_ms, config.daemon_interval_seconds * 1_000),
          running?: false,
          last_result: nil,
          last_action: nil,
          schedule?: Keyword.get(opts, :schedule, true)
        }

        {:ok, maybe_schedule(state, 0)}

      _ ->
        case Config.load(opts) do
          {:ok, config} ->
            init(Keyword.put(opts, :config, config))

          {:error, reason} ->
            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       running?: state.running?,
       current_task_kind: state.current_task_kind,
       last_result: state.last_result,
       last_action: state.last_action
     }, state}
  end

  @impl true
  def handle_cast(:run_once, %State{} = state) do
    {:noreply, tick(state)}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    {:noreply, tick(state)}
  end

  def handle_info({ref, result}, %State{current_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    next_state = %State{state | current_task_ref: nil, current_task_kind: nil, running?: false, last_result: result}
    {:noreply, maybe_schedule(next_state, next_state.interval_ms)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{current_task_ref: ref} = state) do
    next_state = %State{state | current_task_ref: nil, current_task_kind: nil, running?: false, last_result: {:error, reason}}
    {:noreply, maybe_schedule(next_state, next_state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick(%State{running?: true} = state), do: state

  defp tick(%State{} = state) do
    :ok = ControlFiles.ensure(state.config)
    cancel_timer(state.timer_ref)

    case ActiveRuntime.claim(state.config, "elixir") do
      :ok ->
        context = Orchestrator.build_context(state.config)
        decision = Orchestrator.decide(context)

        :ok =
          Events.emit(state.config, :daemon_tick, %{
            "action" => Atom.to_string(decision.action),
            "reason" => decision.reason,
            "runtime_status" => context.runtime_status,
            "pause_requested" => context.pause_requested?,
            "replan_requested" => context.replan_requested?,
            "needs_build" => context.needs_build?,
            "workflow_requested" => context.workflow_requested?,
            "workflow_name" => workflow_name(context.workflow_run_spec),
            "workflow_mode" => workflow_mode(context.workflow_run_spec),
            "workflow_request_error" => format_workflow_request_error(context.workflow_request_error)
          })

        apply_decision(state, decision, context)

      {:error, reason} ->
        maybe_schedule(%State{state | last_action: :runtime_conflict, last_result: {:error, reason}}, state.interval_ms)
    end
  end

  defp apply_decision(%State{} = state, %Orchestrator.Decision{action: :pause}, _context) do
    maybe_write_paused(state.config)
    maybe_schedule(%State{state | last_action: :paused}, state.interval_ms)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :recover, reason: reason},
         _context
       ) do
    {:ok, _} =
      RuntimeLifecycle.transition(state.config, :recovered, :daemon, %{
        surface: "daemon",
        mode: "daemon",
        reason: reason,
        requested_action: "",
        branch: state.config.default_branch
      })

    maybe_schedule(%State{state | last_action: :recovered}, state.interval_ms)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :escalate_blocker},
         %Orchestrator.Context{blocker_result: {:threshold_reached, %{count: count}}}
       ) do
    {:ok, _} =
      Escalation.escalate(state.config, %{
        kind: "blocker",
        summary: "Daemon hit the same unanswered blocker for #{count} consecutive cycles",
        requested_action: "review",
        repeat_count: count,
        surface: "daemon",
        mode: "daemon",
        branch: state.config.default_branch
      })

    maybe_schedule(%State{state | last_action: :blocker_escalated}, state.interval_ms)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :escalate_blocker},
         %Orchestrator.Context{blocker_result: blocker_result}
       ) do
    maybe_schedule(
      %State{
        state
        | last_action: :blocker_invariant_error,
          last_result: {:error, {:unexpected_blocker_result, blocker_result}}
      },
      state.interval_ms
    )
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :idle, persist_idle?: persist_idle?, reason: reason},
         _context
       ) do
    if persist_idle? do
      {:ok, _} =
        RuntimeLifecycle.transition(state.config, :daemon_idle, :daemon, %{
          surface: "daemon",
          mode: "daemon",
          reason: reason,
          requested_action: "",
          branch: state.config.default_branch
        })
    end

    maybe_schedule(%State{state | last_action: :idle}, state.interval_ms)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :workflow_error, error: error},
         _context
       ) do
    result = normalize_managed_start_failure(state.config, workflow_request_identity(state.config), error)

    maybe_schedule(
      %State{state | last_action: :workflow_error, last_result: result},
      state.interval_ms
    )
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: action, run_spec: %RunSpec{} = run_spec, consume_flag: consume_flag},
         _context
       )
       when action in [:plan, :build, :workflow] do
    task =
      Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn ->
        run_managed_via_babysitter(state, run_spec, consume_flag)
      end)

    %State{
      state
      | current_task_ref: task.ref,
        current_task_kind: current_task_kind(run_spec),
        running?: true,
        last_action: decision_last_action(action, run_spec)
    }
  end

  defp run_managed_via_babysitter(%State{} = state, %RunSpec{} = run_spec, consume_flag) do
    case ensure_managed_run_available(state.config) do
      :ok ->
        do_run_managed_via_babysitter(state, run_spec, consume_flag)

      {:error, {:managed_run_active, payload}} ->
        {:stopped, {:managed_run_active, payload}}

      {:error, reason} ->
        normalize_managed_start_failure(state.config, run_spec, reason)
    end
  end

  defp do_run_managed_via_babysitter(%State{} = state, %RunSpec{} = run_spec, consume_flag) do
    try do
      case Babysitter.start_link(
             config: state.config,
             run_spec: run_spec,
             branch: state.config.default_branch,
             runtime_surface: "daemon",
             driver: driver_for_run_spec(state.driver, run_spec),
             driver_opts: state.driver_opts,
             name: nil
           ) do
        {:ok, pid} ->
          case Babysitter.start_run(pid) do
            :ok ->
              case maybe_consume_flag_after_start(state.config, consume_flag) do
                :ok ->
                  case Babysitter.await_result(pid, stop?: true) do
                    {:error, :babysitter_exited} = error -> normalize_managed_start_failure(state.config, run_spec, error)
                    result -> result
                  end

                {:error, reason} ->
                  _ = stop_babysitter(pid)
                  normalize_managed_start_failure(state.config, run_spec, reason)
              end

            {:error, reason} ->
              stop_babysitter(pid)
              normalize_managed_start_failure(state.config, run_spec, reason)
          end

        {:error, reason} ->
          normalize_managed_start_failure(state.config, run_spec, reason)
      end
    catch
      :exit, reason -> normalize_managed_start_failure(state.config, run_spec, {:babysitter_exit, reason})
    end
  end

  defp ensure_managed_run_available(%Config{} = config) do
    case Worktree.active_run_state(config) do
      :missing -> :ok
      {:stale, _payload} -> :ok
      {:active, payload} -> {:error, {:managed_run_active, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_consume_flag_after_start(_config, nil), do: :ok
  defp maybe_consume_flag_after_start(config, flag), do: ControlFiles.consume_flag(config, flag)

  defp normalize_managed_start_failure(config, run_descriptor, reason) do
    summary = managed_start_failure_summary(run_descriptor, reason)
    evidence_file = write_managed_start_error(config, run_descriptor, summary, reason)
    runtime_mode = managed_runtime_mode(run_descriptor)

    case FailureTracker.handle(config, %{
           kind: runtime_mode,
           summary: summary,
           evidence_file: evidence_file,
           requested_action: managed_requested_action(run_descriptor, config),
           surface: "daemon",
           mode: runtime_mode,
           branch: config.default_branch
         }) do
      {:retry, count} -> {:retry, count}
      {:stop, count} -> {:stopped, {:escalated, count}}
      {:error, failure_reason} -> {:error, failure_reason}
    end
  end

  defp managed_start_failure_summary(%RunSpec{} = run_spec, reason),
    do:
      "Managed daemon #{RunSpec.runtime_mode(run_spec)} run failed before loop start: #{format_managed_start_reason(reason)}"

  defp managed_start_failure_summary({:workflow_request, _action, _workflow_name}, reason),
    do: "Managed daemon workflow request failed before loop start: #{format_managed_start_reason(reason)}"

  defp format_managed_start_reason(reason), do: inspect(reason)

  defp write_managed_start_error(%Config{} = config, run_descriptor, summary, reason) do
    path = managed_start_error_file(config, run_descriptor)
    body = [summary, "", inspect(reason), ""] |> Enum.join("\n")

    case ControlLock.with_lock(config, path, :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
           ControlLock.atomic_write(config, path, :runtime, body)
         end) do
      {:ok, :ok} -> path
      _ -> nil
    end
  end

  defp managed_start_error_file(%Config{} = config, %RunSpec{lane: :checklist, action: action}) do
    Path.join([config.v2_state_dir, "babysitter", "daemon-#{action}-start-error-last.txt"])
  end

  defp managed_start_error_file(%Config{} = config, %RunSpec{lane: :workflow, action: action, workflow_name: workflow_name}) do
    Path.join([
      config.v2_state_dir,
      "babysitter",
      "daemon-workflow-#{action}-#{sanitize_file_segment(workflow_name, "workflow")}-start-error-last.txt"
    ])
  end

  defp managed_start_error_file(%Config{} = config, {:workflow_request, action, workflow_name}) do
    Path.join([
      config.v2_state_dir,
      "babysitter",
      "daemon-workflow-#{sanitize_file_segment(action, "invalid-action")}-#{sanitize_file_segment(workflow_name, "workflow")}-start-error-last.txt"
    ])
  end

  defp stop_babysitter(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end

  defp maybe_schedule(%State{schedule?: false} = state, _delay), do: %State{state | timer_ref: nil}

  defp maybe_schedule(%State{} = state, delay) do
    ref = Process.send_after(self(), :tick, delay)
    %State{state | timer_ref: ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref, async: true, info: false)

  defp maybe_write_paused(config) do
    if RuntimeStateStore.status(config) != "awaiting-human" do
      {:ok, _} =
        RuntimeLifecycle.transition(config, :paused_by_operator, :daemon, %{
          surface: "daemon",
          mode: "daemon",
          reason: "Daemon paused via REQUESTS.md",
          requested_action: "",
          branch: config.default_branch
        })
    end
  end

  defp decision_last_action(:workflow, %RunSpec{action: action, workflow_name: workflow_name}),
    do: {:workflow, action, workflow_name}

  defp decision_last_action(action, _run_spec), do: action

  defp current_task_kind(%RunSpec{lane: :workflow} = run_spec), do: RunSpec.runtime_mode(run_spec)
  defp current_task_kind(%RunSpec{action: action}), do: action

  defp managed_runtime_mode(%RunSpec{} = run_spec), do: RunSpec.runtime_mode(run_spec)

  defp managed_runtime_mode({:workflow_request, action, _workflow_name}) when is_binary(action) do
    case String.downcase(String.trim(action)) do
      "preflight" -> "workflow-preflight"
      "run" -> "workflow-run"
      _ -> "workflow"
    end
  end

  defp managed_runtime_mode({:workflow_request, action, _workflow_name}) when is_atom(action) do
    managed_runtime_mode({:workflow_request, Atom.to_string(action), nil})
  end

  defp managed_requested_action(%RunSpec{} = run_spec, %Config{} = config) do
    RunSpec.requested_action(run_spec, config.failure_escalation_action)
  end

  defp managed_requested_action({:workflow_request, _action, _workflow_name}, _config), do: "review"

  defp workflow_request_identity(%Config{} = config) do
    {:workflow_request, config.daemon_workflow_action, config.daemon_workflow_name}
  end

  defp workflow_name(%RunSpec{workflow_name: workflow_name}), do: workflow_name
  defp workflow_name(_), do: nil

  defp workflow_mode(%RunSpec{} = run_spec), do: RunSpec.runtime_mode(run_spec)
  defp workflow_mode(_), do: nil

  defp format_workflow_request_error(nil), do: nil
  defp format_workflow_request_error(reason), do: inspect(reason)

  defp sanitize_file_segment(nil, fallback), do: fallback

  defp sanitize_file_segment(value, fallback) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback
      sanitized -> sanitized
    end
  end

  defp driver_for_run_spec(ForgeloopV2.WorkDrivers.Noop, %RunSpec{lane: :workflow}),
    do: ForgeloopV2.WorkDrivers.ShellLoop

  defp driver_for_run_spec(driver, _run_spec), do: driver
end
