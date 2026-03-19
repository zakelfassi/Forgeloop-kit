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

  alias ForgeloopV2.Config

  @impl true
  def run(mode, %Config{} = config, opts) do
    File.mkdir_p!(Path.join(config.v2_state_dir, "driver"))
    evidence_file = Path.join([config.v2_state_dir, "driver", "#{mode}-last.txt"])
    args = loop_args(mode, Keyword.get(opts, :iterations, 10))
    timeout_ms = timeout_ms(mode, config)

    task =
      Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn ->
        try do
          System.cmd(config.loop_script, args,
            cd: config.repo_root,
            stderr_to_stdout: true
          )
        rescue
          error in ErlangError ->
            case error.original do
              :enoent -> {"command not found: #{config.loop_script}", 127}
              _ -> reraise(error, __STACKTRACE__)
            end
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        File.write!(evidence_file, output)
        {:ok, %{mode: mode, evidence_file: evidence_file}}

      {:ok, {output, _status}} ->
        File.write!(evidence_file, output)
        {:error, %{kind: Atom.to_string(mode), summary: "#{mode} command failed", evidence_file: evidence_file}}

      nil ->
        File.write!(evidence_file, "#{mode} command timed out\n")
        {:error, %{kind: "timeout", summary: "#{mode} command timed out", evidence_file: evidence_file}}
    end
  end

  defp loop_args(:plan, _iterations), do: ["plan", "1"]
  defp loop_args(:build, iterations), do: [to_string(iterations)]
  defp timeout_ms(:plan, config), do: config.plan_timeout_seconds * 1_000
  defp timeout_ms(:build, config), do: config.build_timeout_seconds * 1_000
end

defmodule ForgeloopV2.Loop do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlFiles, FailureTracker, RuntimeStateStore}

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

    {:ok, _state} =
      RuntimeStateStore.write(config, %{
        status: "running",
        transition: if(mode == :plan, do: "planning", else: "building"),
        surface: surface,
        mode: runtime_mode,
        reason: if(mode == :plan, do: "Planning run started", else: "Build run started"),
        requested_action: requested_action,
        branch: branch
      })

    case driver.run(mode, config, driver_opts) do
      {:ok, payload} ->
        :ok = FailureTracker.clear(config)

        if prior_status in ["blocked", "paused", "awaiting-human"] do
          {:ok, _state} =
            RuntimeStateStore.write(config, %{
              status: "recovered",
              transition: "recovered",
              surface: surface,
              mode: runtime_mode,
              reason: "#{mode} recovered",
              requested_action: "",
              branch: branch
            })
        end

        {:ok, _state} =
          RuntimeStateStore.write(config, %{
            status: "idle",
            transition: "completed",
            surface: surface,
            mode: runtime_mode,
            reason: "#{mode} completed",
            requested_action: "",
            branch: branch
          })

        {:ok, payload}

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
    BlockerDetector,
    Config,
    ControlFiles,
    Daemon.State,
    Escalation,
    Loop,
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

    cond do
      ControlFiles.has_flag?(state.config, "PAUSE") ->
        maybe_write_paused(state.config)
        maybe_schedule(%State{state | last_action: :paused}, state.interval_ms)

      needs_recovery?(state.config) ->
        {:ok, _} =
          RuntimeStateStore.write(state.config, %{
            status: "recovered",
            transition: "resuming",
            surface: "daemon",
            mode: "daemon",
            reason: "Pause cleared; resuming daemon",
            requested_action: "",
            branch: state.config.default_branch
          })

        continue_after_recovery(state)

      true ->
        maybe_dispatch(state)
    end
  end

  defp continue_after_recovery(%State{} = state), do: maybe_dispatch(%State{state | last_action: :recovered})

  defp maybe_dispatch(%State{} = state) do
    case BlockerDetector.check(state.config) do
      {:threshold_reached, %{count: count}} ->
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

      _ ->
        case next_work(state.config) do
          :idle ->
            {:ok, _} =
              RuntimeStateStore.write(state.config, %{
                status: "idle",
                transition: "idle",
                surface: "daemon",
                mode: "daemon",
                reason: "No pending work",
                requested_action: "",
                branch: state.config.default_branch
              })

            maybe_schedule(%State{state | last_action: :idle}, state.interval_ms)

          mode ->
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
    end
  end

  defp next_work(config) do
    cond do
      ControlFiles.has_flag?(config, "REPLAN") ->
        :ok = ControlFiles.consume_flag(config, "REPLAN")
        :plan

      needs_build?(config) ->
        :build

      true ->
        :idle
    end
  end

  defp needs_build?(config) do
    case File.read(config.plan_file) do
      {:ok, body} -> Regex.match?(~r/^- \[ \]/m, body)
      {:error, :enoent} -> true
      _ -> true
    end
  end

  defp maybe_schedule(%State{schedule?: false} = state, _delay), do: %State{state | timer_ref: nil}

  defp maybe_schedule(%State{} = state, delay) do
    ref = Process.send_after(self(), :tick, delay)
    %State{state | timer_ref: ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref, async: true, info: false)

  defp needs_recovery?(config) do
    not ControlFiles.has_flag?(config, "PAUSE") and RuntimeStateStore.status(config) in ["paused", "awaiting-human"]
  end

  defp maybe_write_paused(config) do
    if RuntimeStateStore.status(config) != "awaiting-human" do
      {:ok, _} =
        RuntimeStateStore.write(config, %{
          status: "paused",
          transition: "paused",
          surface: "daemon",
          mode: "daemon",
          reason: "Daemon paused via REQUESTS.md",
          requested_action: "",
          branch: config.default_branch
        })
    end
  end
end
