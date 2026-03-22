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

        {:error,
         %{kind: "timeout", summary: "#{mode} command timed out", evidence_file: evidence_file}}

      {output, 0} ->
        File.write!(evidence_file, output)
        {:ok, %{mode: mode, evidence_file: evidence_file}}

      {output, _status} ->
        File.write!(evidence_file, output)

        {:error,
         %{
           kind: Atom.to_string(mode),
           summary: "#{mode} command failed",
           evidence_file: evidence_file
         }}
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
          File.write!(
            artifact_path,
            output <> "#{RunSpec.runtime_mode(spec)} command timed out\n"
          )

          {:error,
           %{
             kind: "timeout",
             summary: "#{RunSpec.runtime_mode(spec)} command timed out",
             evidence_file: artifact_path
           }}

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
        message =
          "workflow runner not found\nSet FORGELOOP_WORKFLOW_RUNNER or install forgeloop-workflow.\n"

        File.write!(artifact_path, message)

        {:error,
         %{
           kind: RunSpec.runtime_mode(spec),
           summary: "workflow runner not found",
           evidence_file: artifact_path
         }}

      {:error, {:invalid_workflow_name, _} = reason} ->
        File.write!(artifact_path, "#{inspect(reason)}\n")

        {:error,
         %{
           kind: RunSpec.runtime_mode(spec),
           summary: inspect(reason),
           evidence_file: artifact_path
         }}

      :missing ->
        File.write!(artifact_path, "workflow not found: #{spec.workflow_name}\n")

        {:error,
         %{
           kind: RunSpec.runtime_mode(spec),
           summary: "workflow not found",
           evidence_file: artifact_path
         }}

      {:error, reason} ->
        File.write!(artifact_path, "#{inspect(reason)}\n")

        {:error,
         %{
           kind: RunSpec.runtime_mode(spec),
           summary: inspect(reason),
           evidence_file: artifact_path
         }}
    end
  end

  defp fetch_workflow_entry(%Config{} = config, workflow_name) do
    WorkflowCatalog.fetch(config, workflow_name)
  end

  defp workflow_package_dir(_config, %Entry{root: root}, nil), do: {:ok, root}

  defp workflow_package_dir(%Config{} = config, %Entry{root: root}, %Worktree.Handle{} = worktree) do
    relative = Path.relative_to(Path.expand(root), config.repo_root)

    cond do
      relative == Path.expand(root) ->
        {:error, {:workflow_root_outside_repo, root, config.repo_root}}

      String.starts_with?(relative, "../") ->
        {:error, {:workflow_root_outside_repo, root, config.repo_root}}

      true ->
        {:ok, Path.join(worktree.checkout_path, relative)}
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
      {"FORGELOOP_RUNTIME_BRANCH",
       to_string(Keyword.get(opts, :runtime_branch, config.default_branch))},
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
    WorkflowHistory,
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
        Keyword.get(
          opts,
          :requested_action,
          RunSpec.requested_action(run_spec, config.failure_escalation_action)
        )

      branch = Keyword.get(opts, :branch, config.default_branch)
      run_id = Keyword.get(opts, :run_id)
      started_at = Keyword.get(opts, :started_at)
      prior_status = RuntimeStateStore.status(config)
      unanswered_question_ids = ControlFiles.unanswered_question_ids(config)
      writer = writer_for(surface)

      case ActiveRuntime.claim(config, %{
             owner: "elixir",
             surface: surface,
             mode: runtime_mode,
             branch: branch
           }) do
        {:ok, claim} ->
          try do
            with {:ok, workspace} <-
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

                  _ =
                    maybe_record_workflow_terminal_outcome(config, run_spec, run_id,
                      outcome: :succeeded,
                      runtime_surface: surface,
                      branch: branch,
                      started_at: started_at,
                      finished_at: iso_now(),
                      summary: completed_reason(run_spec),
                      requested_action: "",
                      runtime_status: RuntimeStateStore.status(config)
                    )

                  {:ok, Map.merge(payload, Workspace.metadata(workspace))}

                {:error, %{kind: kind, summary: summary, evidence_file: evidence_file}} ->
                  if already_escalated?(config) do
                    _ =
                      maybe_record_workflow_terminal_outcome(config, run_spec, run_id,
                        outcome: :escalated,
                        runtime_surface: surface,
                        branch: branch,
                        started_at: started_at,
                        finished_at: iso_now(),
                        summary: summary,
                        requested_action: requested_action,
                        runtime_status: RuntimeStateStore.status(config),
                        failure_kind: kind,
                        error: summary
                      )

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
                      {:retry, count} ->
                        _ =
                          maybe_record_workflow_terminal_outcome(config, run_spec, run_id,
                            outcome: :failed,
                            runtime_surface: surface,
                            branch: branch,
                            started_at: started_at,
                            finished_at: iso_now(),
                            summary: summary,
                            requested_action: requested_action,
                            runtime_status: RuntimeStateStore.status(config),
                            failure_kind: kind,
                            error: summary
                          )

                        {:retry, count}

                      {:stop, count} ->
                        _ =
                          maybe_record_workflow_terminal_outcome(config, run_spec, run_id,
                            outcome: :escalated,
                            runtime_surface: surface,
                            branch: branch,
                            started_at: started_at,
                            finished_at: iso_now(),
                            summary: summary,
                            requested_action: requested_action,
                            runtime_status: RuntimeStateStore.status(config),
                            failure_kind: kind,
                            error: summary
                          )

                        {:stopped, {:escalated, count}}

                      {:error, reason} ->
                        {:error, reason}
                    end
                  end
              end
            else
              {:error, reason} -> {:error, reason}
            end
          after
            _ = ActiveRuntime.release(config, claim["claim_id"])
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_run_spec(%RunSpec{} = spec), do: {:ok, spec}
  defp normalize_run_spec(mode), do: RunSpec.checklist(mode)

  defp default_surface(%RunSpec{lane: :workflow}, opts),
    do: Keyword.get(opts, :surface, "workflow")

  defp default_surface(_spec, opts), do: Keyword.get(opts, :surface, "loop")

  defp started_reason(%RunSpec{lane: :checklist, action: :plan}), do: "Planning run started"
  defp started_reason(%RunSpec{lane: :checklist, action: :build}), do: "Build run started"

  defp started_reason(%RunSpec{lane: :workflow, action: :preflight, workflow_name: name}),
    do: "Workflow preflight started: #{name}"

  defp started_reason(%RunSpec{lane: :workflow, action: :run, workflow_name: name}),
    do: "Workflow run started: #{name}"

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
    ControlFiles.has_flag?(config, "PAUSE") or
      RuntimeStateStore.status(config) == "awaiting-human"
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

  defp maybe_record_workflow_terminal_outcome(
         %Config{} = config,
         %RunSpec{lane: :workflow} = run_spec,
         run_id,
         attrs
       )
       when is_binary(run_id) and is_list(attrs) do
    WorkflowHistory.record_terminal_outcome(config, run_spec, Keyword.put(attrs, :run_id, run_id))
  end

  defp maybe_record_workflow_terminal_outcome(_config, _run_spec, _run_id, _attrs), do: :ok

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
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
    :session_iteration_count,
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
    DaemonStateStore,
    RuntimeLifecycle,
    RuntimeStateStore,
    WorkflowHistory,
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
          session_iteration_count: 0,
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
       last_action: state.last_action,
       session_iteration_count: state.session_iteration_count
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
    {:noreply, finalize_task_result(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{current_task_ref: ref} = state) do
    {:noreply, finalize_task_result(state, {:error, reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick(%State{running?: true} = state), do: state

  defp tick(%State{} = state) do
    :ok = ControlFiles.ensure(state.config)
    cancel_timer(state.timer_ref)

    case maybe_handle_iteration_caps(state) do
      {:ok, capped_state} ->
        capped_state

      {:continue, next_state} ->
        context = Orchestrator.build_context(state.config)
        decision = Orchestrator.decide(context)

        :ok =
          Events.emit(state.config, :daemon_tick, %{
            "action" => Atom.to_string(decision.action),
            "reason" => decision.reason,
            "runtime_status" => context.runtime_status,
            "pause_requested" => context.pause_requested?,
            "replan_requested" => context.replan_requested?,
            "deploy_requested" => context.deploy_requested?,
            "ingest_logs_requested" => context.ingest_logs_requested?,
            "needs_build" => context.needs_build?,
            "workflow_requested" => context.workflow_requested?,
            "workflow_name" => workflow_name(context.workflow_run_spec),
            "workflow_mode" => workflow_mode(context.workflow_run_spec),
            "workflow_request_error" =>
              format_workflow_request_error(context.workflow_request_error)
          })

        apply_decision(next_state, decision, context)
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
    result =
      normalize_managed_start_failure(
        state.config,
        workflow_request_identity(state.config),
        error
      )

    maybe_schedule(
      %State{state | last_action: :workflow_error, last_result: result},
      state.interval_ms
    )
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :deploy, consume_flag: consume_flag},
         _context
       ) do
    spawn_task(state, :deploy, fn -> run_deploy_pipeline(state, consume_flag) end)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{action: :ingest_logs, consume_flag: consume_flag},
         _context
       ) do
    spawn_task(state, :ingest_logs, fn -> run_ingest_logs_request(state, consume_flag) end)
  end

  defp apply_decision(
         %State{} = state,
         %Orchestrator.Decision{
           action: action,
           run_spec: %RunSpec{} = run_spec,
           consume_flag: consume_flag
         },
         _context
       )
       when action in [:plan, :build, :workflow] do
    spawn_task(
      state,
      current_task_kind(run_spec),
      fn ->
        run_managed_via_babysitter(state, run_spec, consume_flag)
      end,
      decision_last_action(action, run_spec)
    )
  end

  defp run_managed_via_babysitter(%State{} = state, %RunSpec{} = run_spec, consume_flag) do
    start_meta = workflow_start_meta(run_spec)

    case ensure_managed_run_available(state.config) do
      :ok ->
        do_run_managed_via_babysitter(state, run_spec, consume_flag, start_meta)

      {:error, {:managed_run_active, payload}} ->
        {:stopped, {:managed_run_active, payload}}

      {:error, reason} ->
        normalize_managed_start_failure(state.config, run_spec, reason, start_meta)
    end
  end

  defp do_run_managed_via_babysitter(
         %State{} = state,
         %RunSpec{} = run_spec,
         consume_flag,
         start_meta
       ) do
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
          case Babysitter.start_run(pid, start_run_meta(start_meta)) do
            :ok ->
              case maybe_consume_flag_after_start(state.config, consume_flag) do
                :ok ->
                  case Babysitter.await_result(pid, stop?: true) do
                    {:error, :babysitter_exited} = error ->
                      normalize_managed_start_failure(state.config, run_spec, error, start_meta)

                    result ->
                      result
                  end

                {:error, reason} ->
                  _ = stop_babysitter(pid)
                  normalize_managed_start_failure(state.config, run_spec, reason, start_meta)
              end

            {:error, reason} ->
              stop_babysitter(pid)
              normalize_managed_start_failure(state.config, run_spec, reason, start_meta)
          end

        {:error, reason} ->
          normalize_managed_start_failure(state.config, run_spec, reason, start_meta)
      end
    catch
      :exit, reason ->
        normalize_managed_start_failure(
          state.config,
          run_spec,
          {:babysitter_exit, reason},
          start_meta
        )
    end
  end

  defp ensure_managed_run_available(%Config{} = config) do
    with :ok <- ensure_runtime_owner_available(config) do
      case Worktree.active_run_state(config) do
        :missing -> :ok
        {:stale, _payload} -> :ok
        {:active, payload} -> {:error, {:managed_run_active, payload}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_runtime_owner_available(%Config{} = config) do
    case ActiveRuntime.status(config) do
      {:ok, %{live?: true, current: current}} when is_map(current) ->
        {:error, {:active_runtime_owned_by, current}}

      {:ok, _status} ->
        :ok
    end
  end

  defp maybe_consume_flag_after_start(_config, nil), do: :ok
  defp maybe_consume_flag_after_start(config, flag), do: ControlFiles.consume_flag(config, flag)

  defp normalize_managed_start_failure(config, run_descriptor, reason, start_meta \\ []) do
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
      {:retry, count} ->
        _ =
          maybe_record_workflow_start_failure(
            config,
            run_descriptor,
            start_meta,
            summary,
            reason,
            RuntimeStateStore.status(config)
          )

        {:retry, count}

      {:stop, count} ->
        _ =
          maybe_record_workflow_start_failure(
            config,
            run_descriptor,
            start_meta,
            summary,
            reason,
            RuntimeStateStore.status(config)
          )

        {:stopped, {:escalated, count}}

      {:error, failure_reason} ->
        _ =
          maybe_record_workflow_start_failure(
            config,
            run_descriptor,
            start_meta,
            summary,
            reason,
            nil
          )

        {:error, failure_reason}
    end
  end

  defp workflow_start_meta(%RunSpec{lane: :workflow} = run_spec) do
    [run_id: WorkflowHistory.generate_run_id(run_spec), started_at: daemon_iso_now()]
  end

  defp workflow_start_meta(_run_spec), do: []

  defp start_run_meta([]), do: []
  defp start_run_meta(meta), do: meta

  defp maybe_record_workflow_start_failure(
         %Config{} = config,
         %RunSpec{lane: :workflow} = run_spec,
         start_meta,
         summary,
         reason,
         runtime_status
       )
       when is_list(start_meta) do
    run_id = Keyword.get(start_meta, :run_id)

    if is_binary(run_id) do
      WorkflowHistory.record_terminal_outcome(config, run_spec,
        run_id: run_id,
        outcome: :start_failed,
        runtime_surface: "daemon",
        branch: config.default_branch,
        started_at: Keyword.get(start_meta, :started_at),
        finished_at: daemon_iso_now(),
        summary: summary,
        requested_action: RunSpec.requested_action(run_spec, config.failure_escalation_action),
        runtime_status: runtime_status,
        failure_kind: managed_runtime_mode(run_spec),
        error: reason
      )
    else
      :ok
    end
  end

  defp maybe_record_workflow_start_failure(
         _config,
         _run_descriptor,
         _start_meta,
         _summary,
         _reason,
         _runtime_status
       ),
       do: :ok

  defp managed_start_failure_summary(%RunSpec{} = run_spec, reason),
    do:
      "Managed daemon #{RunSpec.runtime_mode(run_spec)} run failed before loop start: #{format_managed_start_reason(reason)}"

  defp managed_start_failure_summary({:workflow_request, _action, _workflow_name}, reason),
    do:
      "Managed daemon workflow request failed before loop start: #{format_managed_start_reason(reason)}"

  defp format_managed_start_reason(reason), do: inspect(reason)

  defp write_managed_start_error(%Config{} = config, run_descriptor, summary, reason) do
    path = managed_start_error_file(config, run_descriptor)
    body = [summary, "", inspect(reason), ""] |> Enum.join("\n")

    case ControlLock.with_lock(
           config,
           path,
           :runtime,
           [timeout_ms: config.control_lock_timeout_ms],
           fn ->
             ControlLock.atomic_write(config, path, :runtime, body)
           end
         ) do
      {:ok, :ok} -> path
      _ -> nil
    end
  end

  defp managed_start_error_file(%Config{} = config, %RunSpec{lane: :checklist, action: action}) do
    Path.join([config.v2_state_dir, "babysitter", "daemon-#{action}-start-error-last.txt"])
  end

  defp managed_start_error_file(%Config{} = config, %RunSpec{
         lane: :workflow,
         action: action,
         workflow_name: workflow_name
       }) do
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

  defp spawn_task(state, task_kind, fun, last_action \\ nil)

  defp spawn_task(%State{} = state, task_kind, fun, last_action) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fun)

    last_action = if(is_nil(last_action), do: task_kind, else: last_action)

    %State{
      state
      | current_task_ref: task.ref,
        current_task_kind: task_kind,
        running?: true,
        last_action: last_action
    }
  end

  defp finalize_task_result(%State{} = state, result) do
    task_kind = state.current_task_kind

    next_state =
      %State{
        state
        | current_task_ref: nil,
          current_task_kind: nil,
          running?: false,
          last_result: result
      }
      |> maybe_increment_build_counters(task_kind, result)
      |> maybe_handle_stall(task_kind, result)

    maybe_schedule(next_state, next_delay_ms(next_state.interval_ms, task_kind, result))
  end

  defp maybe_handle_iteration_caps(%State{} = state) do
    today = today_string()

    if iteration_cap_check_deferred?(state.config) do
      {:continue, state}
    else
      with {:ok, daemon_state} <- DaemonStateStore.reset_daily_if_needed(state.config, today) do
        session_hit? =
          state.config.max_session_iterations > 0 and
            state.session_iteration_count >= state.config.max_session_iterations

        daily_count = Map.get(daemon_state, "daily_iteration_count", 0)

        daily_hit? =
          state.config.max_daily_iterations > 0 and
            daily_count >= state.config.max_daily_iterations

        if session_hit? or daily_hit? do
          summary =
            "Iteration cap reached (session=#{state.session_iteration_count}/#{state.config.max_session_iterations}, daily=#{daily_count}/#{state.config.max_daily_iterations})"

          {:ok, _} =
            Escalation.escalate(state.config, %{
              kind: "iteration-cap",
              summary: summary,
              requested_action: "review",
              repeat_count: 0,
              surface: "daemon",
              mode: "daemon",
              branch: state.config.default_branch
            })

          {:ok,
           maybe_schedule(
             %State{
               state
               | last_action: :iteration_cap_escalated,
                 last_result: {:stopped, :iteration_cap}
             },
             state.interval_ms
           )}
        else
          {:continue, state}
        end
      end
    end
  end

  defp maybe_increment_build_counters(%State{} = state, :build, result) do
    if count_build_cycle?(result) do
      _ = DaemonStateStore.increment_daily_iteration(state.config, today_string())
      %State{state | session_iteration_count: state.session_iteration_count + 1}
    else
      state
    end
  end

  defp maybe_increment_build_counters(%State{} = state, _task_kind, _result), do: state

  defp iteration_cap_check_deferred?(%Config{} = config) do
    ControlFiles.has_flag?(config, "PAUSE") or
      RuntimeStateStore.status(config) in ["paused", "awaiting-human"]
  end

  defp maybe_handle_stall(%State{} = state, :build, {:ok, _payload}) do
    cond do
      state.config.max_stall_cycles <= 0 ->
        state

      true ->
        case current_head_hash(state.config.repo_root) do
          {:ok, head_hash} ->
            case DaemonStateStore.record_stall_head(state.config, head_hash) do
              {:ok, %{count: count}} when count >= state.config.max_stall_cycles ->
                summary = "No new commits for #{count} consecutive build cycles — likely stuck"

                {:ok, _} =
                  Escalation.escalate(state.config, %{
                    kind: "stall",
                    summary: summary,
                    requested_action: "review",
                    repeat_count: count,
                    surface: "daemon",
                    mode: "daemon",
                    branch: state.config.default_branch
                  })

                %State{state | last_action: :stall_escalated}

              _ ->
                state
            end

          {:error, reason} ->
            _ =
              Events.emit(state.config, :daemon_stall_check_failed, %{
                "reason" => inspect(reason),
                "surface" => "daemon"
              })

            state
        end
    end
  end

  defp maybe_handle_stall(%State{} = state, _task_kind, _result), do: state

  defp count_build_cycle?({:ok, _payload}), do: true
  defp count_build_cycle?({:retry, _count}), do: true
  defp count_build_cycle?({:stopped, _reason}), do: true
  defp count_build_cycle?(_result), do: false

  defp next_delay_ms(_interval_ms, task_kind, {:ok, _payload})
       when task_kind in [:plan, :deploy, :ingest_logs], do: 0

  defp next_delay_ms(interval_ms, _task_kind, _result), do: interval_ms

  defp run_deploy_pipeline(%State{} = state, consume_flag) do
    with :ok <- consume_flag_before_action(state.config, consume_flag) do
      do_run_deploy_pipeline(state)
    end
  end

  defp do_run_deploy_pipeline(%State{} = state) do
    config = state.config

    if blank?(config.deploy_cmd) do
      _ =
        Events.emit(config, :daemon_deploy_completed, %{
          "surface" => "daemon",
          "requested_action" => "deploy",
          "skipped" => true,
          "reason" => "FORGELOOP_DEPLOY_CMD not configured"
        })

      {:ok, %{mode: :deploy, skipped?: true}}
    else
      :ok =
        Events.emit(config, :daemon_deploy_started, %{
          "surface" => "daemon",
          "requested_action" => "deploy"
        })

      {:ok, _} =
        RuntimeLifecycle.transition(config, :loop_started, :daemon, %{
          surface: "daemon",
          mode: "deploy",
          reason: "Running deploy pipeline",
          requested_action: "deploy",
          branch: config.default_branch
        })

      with :ok <-
             run_deploy_stage(config, "pre", "Deploy pre-check command", config.deploy_pre_cmd),
           :ok <- run_deploy_stage(config, "deploy", "Deploy command", config.deploy_cmd),
           :ok <- maybe_wait_after_deploy(config),
           :ok <-
             run_deploy_stage(config, "smoke", "Deploy smoke command", config.deploy_smoke_cmd),
           :ok <- maybe_post_deploy_ingest(config) do
        :ok = FailureTracker.clear(config)

        {:ok, _} =
          RuntimeStateStore.write(config, %{
            status: "recovered",
            transition: "deploy-completed",
            surface: "daemon",
            mode: "daemon",
            reason: "Deploy pipeline completed successfully",
            requested_action: "deploy",
            branch: config.default_branch
          })

        :ok =
          Events.emit(config, :daemon_deploy_completed, %{
            "surface" => "daemon",
            "requested_action" => "deploy",
            "skipped" => false
          })

        {:ok, %{mode: :deploy}}
      else
        {:retry, _count} = retry ->
          emit_deploy_failure_event(config, retry)
          retry

        {:stopped, _reason} = stopped ->
          emit_deploy_failure_event(config, stopped)
          stopped

        {:error, reason} = error ->
          emit_deploy_failure_event(config, reason)
          error
      end
    end
  end

  defp run_ingest_logs_request(%State{} = state, consume_flag) do
    with :ok <- consume_flag_before_action(state.config, consume_flag) do
      do_run_ingest_logs(state.config, emit_events?: true)
    end
  end

  defp do_run_ingest_logs(%Config{} = config, opts) do
    emit_events? = Keyword.get(opts, :emit_events?, false)
    ingest_script = Path.join(config.forgeloop_root, "bin/ingest-logs.sh")

    cond do
      not File.exists?(ingest_script) ->
        maybe_emit_ingest_event(
          config,
          :daemon_ingest_logs_completed,
          true,
          "ingest script not available",
          emit_events?
        )

        {:ok, %{mode: :ingest_logs, skipped?: true}}

      blank?(config.ingest_logs_cmd) and blank?(config.ingest_logs_file) ->
        maybe_emit_ingest_event(
          config,
          :daemon_ingest_logs_completed,
          true,
          "no log source configured",
          emit_events?
        )

        {:ok, %{mode: :ingest_logs, skipped?: true}}

      true ->
        maybe_emit_ingest_event(config, :daemon_ingest_logs_started, false, nil, emit_events?)

        case System.cmd(ingest_script, ingest_args(config),
               cd: config.repo_root,
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            maybe_emit_ingest_event(
              config,
              :daemon_ingest_logs_completed,
              false,
              nil,
              emit_events?
            )

            {:ok, %{mode: :ingest_logs}}

          {output, status} ->
            maybe_emit_ingest_event(
              config,
              :daemon_ingest_logs_failed,
              false,
              "status=#{status}: #{String.trim(output)}",
              emit_events?
            )

            {:error, {:ingest_logs_failed, status}}
        end
    end
  end

  defp maybe_post_deploy_ingest(%Config{post_deploy_ingest_logs: true} = config) do
    case do_run_ingest_logs(config, emit_events?: false) do
      {:ok, _payload} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_post_deploy_ingest(%Config{}), do: :ok

  defp maybe_wait_after_deploy(%Config{
         post_deploy_ingest_logs: true,
         post_deploy_observe_seconds: seconds
       })
       when is_integer(seconds) and seconds > 0 do
    Process.sleep(seconds * 1_000)
    :ok
  end

  defp maybe_wait_after_deploy(_config), do: :ok

  defp run_deploy_stage(%Config{} = _config, _stage_id, _label, command)
       when command in [nil, ""], do: :ok

  defp run_deploy_stage(%Config{} = config, stage_id, label, command) do
    deploy_dir = Path.join(config.runtime_dir, "deploy")
    File.mkdir_p!(deploy_dir)
    output_path = Path.join(deploy_dir, "#{stage_id}-last.txt")

    case shell_command(command, config.repo_root) do
      {output, 0} ->
        File.write!(output_path, output)
        :ok

      {output, _status} ->
        File.write!(output_path, output)

        FailureTracker.handle(config, %{
          kind: "deploy",
          summary: "#{label} failed: #{command}",
          evidence_file: output_path,
          requested_action: "review",
          surface: "daemon",
          mode: "daemon",
          branch: config.default_branch
        })
    end
  end

  defp consume_flag_before_action(_config, nil), do: :ok
  defp consume_flag_before_action(config, flag), do: ControlFiles.consume_flag(config, flag)

  defp emit_deploy_failure_event(%Config{} = config, reason) do
    :ok =
      Events.emit(config, :daemon_deploy_failed, %{
        "surface" => "daemon",
        "requested_action" => "deploy",
        "reason" => inspect(reason)
      })
  end

  defp maybe_emit_ingest_event(_config, _event, _skipped?, _reason, false), do: :ok

  defp maybe_emit_ingest_event(%Config{} = config, event, skipped?, reason, true) do
    :ok =
      Events.emit(config, event, %{
        "surface" => "daemon",
        "requested_action" => "ingest_logs",
        "skipped" => skipped?,
        "reason" => reason
      })
  end

  defp ingest_args(%Config{} = config) do
    args = ["--requests", requests_file_arg(config)]

    args =
      cond do
        not blank?(config.ingest_logs_cmd) ->
          args ++ ["--cmd", config.ingest_logs_cmd, "--source", "daemon"]

        true ->
          args ++ ["--file", config.ingest_logs_file, "--source", "daemon"]
      end

    if is_integer(config.ingest_logs_tail) and config.ingest_logs_tail > 0 do
      args ++ ["--tail", Integer.to_string(config.ingest_logs_tail)]
    else
      args
    end
  end

  defp requests_file_arg(%Config{} = config) do
    case Path.type(config.requests_file) do
      :relative ->
        config.requests_file

      :absolute ->
        repo_relative_path(
          config.requests_file,
          config.repo_root,
          Path.basename(config.requests_file)
        )

      _ ->
        Path.basename(config.requests_file)
    end
  end

  defp repo_relative_path(path, repo_root, fallback) do
    relative = Path.relative_to(path, repo_root)

    if relative == path or String.starts_with?(relative, "../") do
      fallback
    else
      relative
    end
  end

  defp shell_command(command, repo_root) do
    shell = System.find_executable("bash") || "/bin/bash"
    System.cmd(shell, ["-lc", command], cd: repo_root, stderr_to_stdout: true)
  end

  defp current_head_hash(repo_root) do
    case System.cmd("git", ["-C", repo_root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_rev_parse_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp today_string do
    NaiveDateTime.local_now()
    |> NaiveDateTime.to_date()
    |> Date.to_iso8601()
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp maybe_schedule(%State{schedule?: false} = state, _delay),
    do: %State{state | timer_ref: nil}

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

  defp managed_requested_action({:workflow_request, _action, _workflow_name}, _config),
    do: "review"

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
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp daemon_iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp driver_for_run_spec(ForgeloopV2.WorkDrivers.Noop, %RunSpec{lane: :workflow}),
    do: ForgeloopV2.WorkDrivers.ShellLoop

  defp driver_for_run_spec(driver, _run_spec), do: driver
end
