defmodule ForgeloopV2.WorkDriver do
  @moduledoc false

  alias ForgeloopV2.Config

  @callback run(:plan | :build, Config.t(), keyword()) ::
              {:ok, %{mode: :plan | :build, evidence_file: Path.t() | nil}}
              | {:error, %{kind: String.t(), summary: String.t(), evidence_file: Path.t() | nil}}
end

defmodule ForgeloopV2.WorkDrivers.Noop do
  @moduledoc false
  @behaviour ForgeloopV2.WorkDriver

  @impl true
  def run(mode, _config, opts) do
    scenario = Keyword.get(opts, mode) || Keyword.get(opts, :result, {:ok, %{}})

    result =
      cond do
        is_function(scenario, 1) -> scenario.(mode)
        true -> scenario
      end

    case result do
      {:ok, payload} when is_map(payload) ->
        {:ok, Map.put_new(payload, :mode, mode) |> Map.put_new(:evidence_file, nil)}

      {:error, payload} when is_map(payload) ->
        {:error,
         payload
         |> Map.put_new(:kind, Atom.to_string(mode))
         |> Map.put_new(:summary, "#{mode} failed")
         |> Map.put_new(:evidence_file, nil)}

      _ ->
        {:ok, %{mode: mode, evidence_file: nil}}
    end
  end
end

defmodule ForgeloopV2.WorkDrivers.ShellLoop do
  @moduledoc false
  @behaviour ForgeloopV2.WorkDriver

  alias ForgeloopV2.{Config, Worktree}

  @impl true
  def run(mode, %Config{} = config, opts) do
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
      {"FORGELOOP_RUNTIME_BRANCH", to_string(Keyword.get(opts, :runtime_branch, config.default_branch))}
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
end

defmodule ForgeloopV2.Loop do
  @moduledoc false

  alias ForgeloopV2.{
    ActiveRuntime,
    Config,
    ControlFiles,
    FailureTracker,
    RuntimeLifecycle,
    RuntimeRecovery,
    RuntimeState,
    RuntimeStateStore,
    Workspace
  }

  @spec run(:plan | :build, Config.t(), keyword()) ::
          {:ok, map()} | {:retry, pos_integer()} | {:stopped, term()} | {:error, term()}
  def run(mode, %Config{} = config, opts \\ []) do
    driver = Keyword.get(opts, :driver, default_driver(config))
    driver_opts = Keyword.get(opts, :driver_opts, [])
    surface = Keyword.get(opts, :surface, "loop")
    runtime_mode = Keyword.get(opts, :runtime_mode, Atom.to_string(mode))
    requested_action = Keyword.get(opts, :requested_action, config.failure_escalation_action)
    branch = Keyword.get(opts, :branch, config.default_branch)
    prior_status = RuntimeStateStore.status(config)
    unanswered_question_ids = ControlFiles.unanswered_question_ids(config)
    writer = writer_for(surface)

    with :ok <- ActiveRuntime.claim(config, "elixir"),
         {:ok, workspace} <- Workspace.from_config(config, branch: branch, mode: runtime_mode, kind: Atom.to_string(mode)),
         {:ok, _state} <-
           maybe_write_recovered(
             config,
             prior_status,
             unanswered_question_ids,
             writer,
             surface,
             runtime_mode,
             branch,
             mode
           ),
         {:ok, _state} <-
           RuntimeLifecycle.transition(config, :loop_started, writer, %{
             surface: surface,
             mode: runtime_mode,
             reason: if(mode == :plan, do: "Planning run started", else: "Build run started"),
             requested_action: requested_action,
             branch: branch
           }) do
      case driver.run(mode, config, driver_opts) do
        {:ok, payload} ->
          :ok = FailureTracker.clear(config)

          {:ok, _state} =
            RuntimeLifecycle.transition(config, :loop_completed, writer, %{
              surface: surface,
              mode: runtime_mode,
              reason: "#{mode} completed",
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

  defp default_driver(config) do
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
         mode
       ) do
    case RuntimeRecovery.evaluate(prior_status, unanswered_question_ids, allow_blocked?: true) do
      {:recover, kind} ->
        RuntimeLifecycle.transition(config, :recovered, writer, %{
          surface: surface,
          mode: runtime_mode,
          reason: recovery_reason(kind, mode),
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
    Config,
    ControlFiles,
    Daemon.State,
    Escalation,
    Events,
    Loop,
    Orchestrator,
    RuntimeLifecycle,
    RuntimeStateStore
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
            "needs_build" => context.needs_build?
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
         %Orchestrator.Decision{action: mode, consume_replan?: consume_replan?},
         _context
       )
       when mode in [:plan, :build] do
    if consume_replan?, do: :ok = ControlFiles.consume_flag(state.config, "REPLAN")

    task =
      Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn ->
        Loop.run(mode, state.config,
          driver: state.driver,
          driver_opts: state.driver_opts,
          surface: "daemon",
          runtime_mode: Atom.to_string(mode),
          branch: state.config.default_branch
        )
      end)

    %State{
      state
      | current_task_ref: task.ref,
        current_task_kind: mode,
        running?: true,
        last_action: mode
    }
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
end
