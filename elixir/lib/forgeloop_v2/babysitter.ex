defmodule ForgeloopV2.Babysitter.State do
  @moduledoc false

  defstruct [
    :config,
    :mode,
    :driver,
    :driver_opts,
    :branch,
    :heartbeat_interval_ms,
    :shutdown_grace_ms,
    :workspace,
    :worktree,
    :current_task,
    :heartbeat_timer_ref,
    :started_at,
    :running?,
    :stopping?,
    :last_result,
    :last_action,
    :last_heartbeat_at,
    cleanup_stale?: true
  ]
end

defmodule ForgeloopV2.Babysitter do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    ActiveRuntime,
    Config,
    ControlFiles,
    ControlLock,
    Events,
    Loop,
    RuntimeLifecycle,
    Worktree,
    Workspace
  }

  alias ForgeloopV2.Babysitter.State

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec start_run(GenServer.server()) :: :ok | {:error, term()}
  def start_run(server \\ __MODULE__) do
    GenServer.call(server, :start_run, :infinity)
  end

  @spec stop_child(GenServer.server(), :pause | :kill) :: :ok
  def stop_child(server \\ __MODULE__, reason \\ :pause) do
    GenServer.call(server, {:stop_child, reason}, :infinity)
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
          mode: Keyword.get(opts, :mode, :build),
          driver: Keyword.get(opts, :driver, default_driver(config)),
          driver_opts: Keyword.get(opts, :driver_opts, []),
          branch: Keyword.get(opts, :branch, config.default_branch),
          heartbeat_interval_ms:
            Keyword.get(opts, :heartbeat_interval_ms, config.babysitter_heartbeat_interval_ms),
          shutdown_grace_ms:
            Keyword.get(opts, :shutdown_grace_ms, config.babysitter_shutdown_grace_ms),
          running?: false,
          stopping?: false,
          last_result: nil,
          last_action: nil,
          last_heartbeat_at: nil,
          started_at: nil,
          cleanup_stale?: Keyword.get(opts, :cleanup_stale?, true)
        }

        {:ok, state}

      _ ->
        case Config.load(opts) do
          {:ok, config} -> init(Keyword.put(opts, :config, config))
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       running?: state.running?,
       stopping?: state.stopping?,
       current_task_kind: if(state.running?, do: state.mode, else: nil),
       workspace_id: state.workspace && state.workspace.workspace_id,
       worktree_path: state.worktree && state.worktree.checkout_path,
       last_action: state.last_action,
       last_result: state.last_result,
       last_heartbeat_at: state.last_heartbeat_at
     }, state}
  end

  def handle_call(:start_run, _from, %State{running?: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:start_run, _from, %State{} = state) do
    case do_start_run(state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_result: {:error, reason}, last_action: :start_failed}}
    end
  end

  def handle_call({:stop_child, _reason}, _from, %State{running?: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:stop_child, reason}, _from, %State{} = state) do
    {:reply, :ok, do_stop_child(state, reason)}
  end

  @impl true
  def handle_info({ref, result}, %State{current_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{current_task: %Task{ref: ref}} = state) do
    {:noreply, finish_run(state, {:error, {:task_down, reason}})}
  end

  def handle_info({:heartbeat, task_ref}, %State{current_task: %Task{ref: task_ref}, running?: true} = state) do
    next_state = write_heartbeat(state)
    {:noreply, next_state}
  end

  def handle_info({:heartbeat, _task_ref}, %State{} = state) do
    {:noreply, state}
  end

  defp do_start_run(%State{} = state) do
    with :ok <- ActiveRuntime.claim(state.config, "elixir"),
         {:ok, _cleaned} <- maybe_cleanup_stale(state),
         {:ok, workspace} <- Workspace.from_config(state.config, branch: state.branch, mode: Atom.to_string(state.mode), kind: "babysitter"),
         {:ok, worktree} <- Worktree.prepare(state.config, workspace) do
      started_at = iso_now()

      with :ok <- write_active_run(state.config, active_run_payload(state, workspace, worktree, "running", started_at, started_at)),
           :ok <- emit_started(state, workspace, worktree) do
        task =
          Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn ->
            Loop.run(state.mode, state.config,
              driver: state.driver,
              driver_opts:
                state.driver_opts
                |> Keyword.put(:worktree, worktree)
                |> Keyword.put(:runtime_branch, state.branch),
              surface: "babysitter",
              runtime_mode: Atom.to_string(state.mode),
              branch: state.branch
            )
          end)

        {:ok,
         %{state |
           workspace: workspace,
           worktree: worktree,
           current_task: task,
           heartbeat_timer_ref: schedule_heartbeat(task.ref, state.heartbeat_interval_ms),
           running?: true,
           stopping?: false,
           last_result: nil,
           last_action: :started,
           last_heartbeat_at: started_at,
           started_at: started_at}}
      else
        {:error, reason} ->
          _ = Worktree.cleanup(state.config, worktree)
          {:error, reason}
      end
    end
  end

  defp maybe_cleanup_stale(%State{cleanup_stale?: true, config: config}) do
    Worktree.cleanup_stale(config)
  end

  defp maybe_cleanup_stale(%State{}), do: {:ok, []}

  defp emit_started(%State{} = state, workspace, worktree) do
    Events.emit(state.config, :babysitter_started, %{
      "workspace_id" => workspace.workspace_id,
      "mode" => Atom.to_string(state.mode),
      "branch" => state.branch,
      "worktree_path" => worktree.checkout_path,
      "surface" => "babysitter"
    })

    :ok
  end

  defp write_heartbeat(%State{} = state) do
    heartbeat_at = iso_now()

    _ =
      write_active_run(
        state.config,
        active_run_payload(
          state,
          state.workspace,
          state.worktree,
          if(state.stopping?, do: "stopping", else: "running"),
          state.started_at || heartbeat_at,
          heartbeat_at
        )
      )

    Events.emit(state.config, :babysitter_heartbeat, %{
      "workspace_id" => state.workspace.workspace_id,
      "mode" => Atom.to_string(state.mode),
      "branch" => state.branch,
      "last_heartbeat_at" => heartbeat_at
    })

    %{state |
      last_heartbeat_at: heartbeat_at,
      heartbeat_timer_ref: schedule_heartbeat(state.current_task.ref, state.heartbeat_interval_ms)}
  end

  defp do_stop_child(%State{current_task: %Task{} = task} = state, reason) do
    cancel_timer(state.heartbeat_timer_ref)
    result = Task.shutdown(task, state.shutdown_grace_ms)
    Process.demonitor(task.ref, [:flush])

    _ = ControlFiles.append_pause_flag(state.config)

    _ =
      RuntimeLifecycle.transition(state.config, :paused_by_operator, :babysitter, %{
        surface: "babysitter",
        mode: Atom.to_string(state.mode),
        reason: stop_reason(reason),
        branch: state.branch
      })

    _ = delete_active_run(state.config)
    _ = maybe_cleanup_worktree(state)

    Events.emit(state.config, :babysitter_stopped, %{
      "workspace_id" => state.workspace && state.workspace.workspace_id,
      "mode" => Atom.to_string(state.mode),
      "branch" => state.branch,
      "reason" => Atom.to_string(reason),
      "forced" => is_nil(result)
    })

    %{state |
      running?: false,
      stopping?: false,
      current_task: nil,
      heartbeat_timer_ref: nil,
      worktree: nil,
      workspace: nil,
      last_result: {:stopped, reason},
      last_action: :stopped,
      last_heartbeat_at: state.last_heartbeat_at,
      started_at: nil}
  end

  defp finish_run(%State{} = state, result) do
    cancel_timer(state.heartbeat_timer_ref)
    _ = delete_active_run(state.config)
    _ = maybe_cleanup_worktree(state)

    {event_type, action} =
      case result do
        {:ok, _payload} -> {:babysitter_completed, :completed}
        _ -> {:babysitter_failed, :failed}
      end

    Events.emit(state.config, event_type, %{
      "workspace_id" => state.workspace && state.workspace.workspace_id,
      "mode" => Atom.to_string(state.mode),
      "branch" => state.branch,
      "result" => inspect(result)
    })

    %{state |
      running?: false,
      stopping?: false,
      current_task: nil,
      heartbeat_timer_ref: nil,
      worktree: nil,
      workspace: nil,
      last_result: result,
      last_action: action,
      started_at: nil}
  end

  defp active_run_payload(%State{} = state, workspace, worktree, status, started_at, heartbeat_at) do
    %{
      "workspace_id" => workspace.workspace_id,
      "mode" => Atom.to_string(state.mode),
      "branch" => state.branch,
      "surface" => "babysitter",
      "worktree_path" => worktree.checkout_path,
      "loop_script_path" => worktree.loop_script_path,
      "started_at" => started_at,
      "last_heartbeat_at" => heartbeat_at,
      "status" => status
    }
  end

  defp write_active_run(%Config{} = config, payload) do
    target = Worktree.active_run_path(config)
    body = Jason.encode!(payload, pretty: true) <> "\n"

    with {:ok, result} <-
           ControlLock.with_lock(config, target, :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
             ControlLock.atomic_write(config, target, :runtime, body)
           end) do
      result
    end
  end

  defp delete_active_run(%Config{} = config) do
    target = Worktree.active_run_path(config)

    with {:ok, result} <-
           ControlLock.with_lock(config, target, :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
             case File.rm(target) do
               :ok -> :ok
               {:error, :enoent} -> :ok
               {:error, reason} -> {:error, reason}
             end
           end) do
      result
    end
  end

  defp maybe_cleanup_worktree(%State{worktree: nil}), do: :ok
  defp maybe_cleanup_worktree(%State{config: config, worktree: worktree}), do: Worktree.cleanup(config, worktree)

  defp schedule_heartbeat(task_ref, interval_ms) do
    Process.send_after(self(), {:heartbeat, task_ref}, interval_ms)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp stop_reason(:kill), do: "Babysitter killed child run"
  defp stop_reason(_reason), do: "Babysitter paused child run"

  defp default_driver(config) do
    if config.shell_driver_enabled, do: ForgeloopV2.WorkDrivers.ShellLoop, else: ForgeloopV2.WorkDrivers.Noop
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
