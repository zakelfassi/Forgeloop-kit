defmodule ForgeloopV2.Babysitter.State do
  @moduledoc false

  defstruct [
    :config,
    :run_spec,
    :driver,
    :driver_opts,
    :branch,
    :runtime_surface,
    :heartbeat_interval_ms,
    :shutdown_grace_ms,
    :workspace,
    :worktree,
    :current_task,
    :heartbeat_timer_ref,
    :started_at,
    :run_id,
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
    RunSpec,
    RuntimeLifecycle,
    WorkflowHistory,
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

  @spec start_run(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def start_run(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:start_run, opts}, :infinity)
  end

  @spec stop_child(GenServer.server(), :pause | :kill) :: :ok | {:error, term()}
  def stop_child(server \\ __MODULE__, reason \\ :pause) do
    GenServer.call(server, {:stop_child, reason}, :infinity)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @spec await_result(GenServer.server(), keyword()) ::
          {:ok, map()} | {:retry, pos_integer()} | {:stopped, term()} | {:error, term()}
  def await_result(server \\ __MODULE__, opts \\ []) do
    do_await_result(
      server,
      Keyword.get(opts, :poll_interval_ms, 20),
      Keyword.get(opts, :stop?, false),
      Keyword.get(opts, :stop_timeout_ms, 5_000)
    )
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        Process.flag(:trap_exit, true)

        with {:ok, run_spec} <- normalize_run_spec(Keyword.get(opts, :run_spec, Keyword.get(opts, :mode, :build))) do
          state = %State{
            config: config,
            run_spec: run_spec,
            driver: Keyword.get(opts, :driver, default_driver(config, run_spec)),
          driver_opts: Keyword.get(opts, :driver_opts, []),
          branch: Keyword.get(opts, :branch, config.default_branch),
          runtime_surface: Keyword.get(opts, :runtime_surface, "babysitter"),
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
          run_id: nil,
            cleanup_stale?: Keyword.get(opts, :cleanup_stale?, true)
          }

          {:ok, state}
        end

      _ ->
        case Config.load(opts) do
          {:ok, config} -> init(Keyword.put(opts, :config, config))
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    cancel_timer(state.heartbeat_timer_ref)

    if match?(%Task{}, state.current_task) do
      _ = Task.shutdown(state.current_task, state.shutdown_grace_ms)
      Process.demonitor(state.current_task.ref, [:flush])
    end

    _ = delete_active_run(state.config)
    _ = maybe_cleanup_worktree(state)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       running?: state.running?,
       stopping?: state.stopping?,
       lane: lane_string(state.run_spec),
       action: action_string(state.run_spec),
       mode: mode_string(state.run_spec),
       workflow_name: workflow_name(state.run_spec),
       run_id: state.run_id,
       current_task_kind: if(state.running?, do: mode_string(state.run_spec), else: nil),
       runtime_surface: state.runtime_surface,
       workspace_id: state.workspace && state.workspace.workspace_id,
       worktree_path: state.worktree && state.worktree.checkout_path,
       last_action: state.last_action,
       last_result: state.last_result,
       last_heartbeat_at: state.last_heartbeat_at
     }, state}
  end

  def handle_call({:start_run, _opts}, _from, %State{running?: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:start_run, opts}, _from, %State{} = state) do
    case do_start_run(state, opts) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_result: {:error, reason}, last_action: :start_failed}}
    end
  end

  def handle_call({:stop_child, _reason}, _from, %State{running?: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:stop_child, reason}, _from, %State{} = state) do
    case do_stop_child(state, reason) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, stop_reason, next_state} -> {:reply, {:error, stop_reason}, next_state}
    end
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

  def handle_info({:EXIT, _pid_or_port, _reason}, %State{} = state) do
    {:noreply, state}
  end

  defp do_start_run(%State{} = state, run_opts) do
    with :ok <- ActiveRuntime.claim(state.config, "elixir"),
         {:ok, _cleaned} <- maybe_cleanup_stale(state),
         {:ok, workspace} <- Workspace.from_config(state.config, branch: state.branch, mode: mode_string(state.run_spec), kind: workspace_kind(state.run_spec)),
         {:ok, worktree} <- Worktree.prepare(state.config, workspace) do
      started_at = Keyword.get(run_opts, :started_at, iso_now())
      run_id = Keyword.get(run_opts, :run_id) || maybe_generate_run_id(state.run_spec)

      with :ok <- write_active_run(state.config, active_run_payload(state, workspace, worktree, run_id, "running", started_at, started_at)),
           :ok <- emit_started(state, workspace, worktree, run_id) do
        task =
          Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn ->
            Loop.run(state.run_spec, state.config,
              driver: state.driver,
              driver_opts:
                state.driver_opts
                |> Keyword.put(:worktree, worktree)
                |> Keyword.put(:runtime_branch, state.branch)
                |> maybe_put_runner_args(run_opts),
              surface: state.runtime_surface,
              runtime_mode: mode_string(state.run_spec),
              branch: state.branch,
              run_id: run_id,
              started_at: started_at
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
           started_at: started_at,
           run_id: run_id}}
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

  defp emit_started(%State{} = state, workspace, worktree, run_id) do
    Events.emit(state.config, :babysitter_started, %{
      "run_id" => run_id,
      "workspace_id" => workspace.workspace_id,
      "lane" => lane_string(state.run_spec),
      "action" => action_string(state.run_spec),
      "mode" => mode_string(state.run_spec),
      "workflow_name" => workflow_name(state.run_spec),
      "branch" => state.branch,
      "worktree_path" => worktree.checkout_path,
      "surface" => "babysitter",
      "runtime_surface" => state.runtime_surface
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
          state.run_id,
          if(state.stopping?, do: "stopping", else: "running"),
          state.started_at || heartbeat_at,
          heartbeat_at
        )
      )

    Events.emit(state.config, :babysitter_heartbeat, %{
      "workspace_id" => state.workspace.workspace_id,
      "run_id" => state.run_id,
      "lane" => lane_string(state.run_spec),
      "action" => action_string(state.run_spec),
      "mode" => mode_string(state.run_spec),
      "workflow_name" => workflow_name(state.run_spec),
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

    pause_write_result = ControlFiles.append_pause_flag(state.config)

    runtime_result =
      RuntimeLifecycle.transition(state.config, :paused_by_operator, :babysitter, %{
        surface: "babysitter",
        mode: mode_string(state.run_spec),
        reason: stop_reason(reason),
        branch: state.branch
      })

    stopped_at = iso_now()
    _ = maybe_record_stopped_workflow(state, reason, stopped_at)
    _ = delete_active_run(state.config)
    _ = maybe_cleanup_worktree(state)

    stop_error = first_stop_error(pause_write_result, runtime_result)

    Events.emit(state.config, :babysitter_stopped, %{
      "workspace_id" => state.workspace && state.workspace.workspace_id,
      "run_id" => state.run_id,
      "lane" => lane_string(state.run_spec),
      "action" => action_string(state.run_spec),
      "mode" => mode_string(state.run_spec),
      "workflow_name" => workflow_name(state.run_spec),
      "branch" => state.branch,
      "runtime_surface" => state.runtime_surface,
      "reason" => Atom.to_string(reason),
      "forced" => is_nil(result),
      "error" => if(stop_error, do: inspect(stop_error), else: nil)
    })

    next_state =
      %{state |
        running?: false,
        stopping?: false,
        current_task: nil,
        heartbeat_timer_ref: nil,
        worktree: nil,
        workspace: nil,
        last_result: if(stop_error, do: {:stop_error, stop_error}, else: {:stopped, reason}),
        last_action: :stopped,
        last_heartbeat_at: state.last_heartbeat_at,
        started_at: nil,
        run_id: nil}

    case stop_error do
      nil -> {:ok, next_state}
      error -> {:error, error, next_state}
    end
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
      "run_id" => state.run_id,
      "lane" => lane_string(state.run_spec),
      "action" => action_string(state.run_spec),
      "mode" => mode_string(state.run_spec),
      "workflow_name" => workflow_name(state.run_spec),
      "branch" => state.branch,
      "runtime_surface" => state.runtime_surface,
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
      started_at: nil,
      run_id: nil}
  end

  defp active_run_payload(%State{} = state, workspace, worktree, run_id, status, started_at, heartbeat_at) do
    %{
      "workspace_id" => workspace.workspace_id,
      "run_id" => run_id,
      "lane" => lane_string(state.run_spec),
      "action" => action_string(state.run_spec),
      "mode" => mode_string(state.run_spec),
      "workflow_name" => workflow_name(state.run_spec),
      "branch" => state.branch,
      "surface" => "babysitter",
      "runtime_surface" => state.runtime_surface,
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

  defp do_await_result(server, poll_interval_ms, stop?, stop_timeout_ms) do
    case safe_snapshot(server) do
      {:ok, %{running?: true}} ->
        Process.sleep(poll_interval_ms)
        do_await_result(server, poll_interval_ms, stop?, stop_timeout_ms)

      {:ok, %{last_result: result}} when not is_nil(result) ->
        if stop?, do: safe_stop(server, stop_timeout_ms)
        result

      {:ok, _snapshot} ->
        if stop?, do: safe_stop(server, stop_timeout_ms)
        {:error, :babysitter_exited}

      :error ->
        {:error, :babysitter_exited}
    end
  end

  defp safe_snapshot(server) do
    {:ok, snapshot(server)}
  catch
    :exit, _reason -> :error
  end

  defp safe_stop(server, timeout_ms) do
    try do
      GenServer.stop(server, :normal, timeout_ms)
    catch
      :exit, _reason -> :ok
    end
  end

  defp schedule_heartbeat(task_ref, interval_ms) do
    Process.send_after(self(), {:heartbeat, task_ref}, interval_ms)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp first_stop_error(:ok, {:ok, _state}), do: nil
  defp first_stop_error(:ok, {:error, reason}), do: reason
  defp first_stop_error({:error, reason}, _runtime_result), do: reason
  defp first_stop_error(_other, {:error, reason}), do: reason
  defp first_stop_error(_other, _runtime_result), do: nil

  defp stop_reason(:kill), do: "Babysitter killed child run"
  defp stop_reason(_reason), do: "Babysitter paused child run"

  defp maybe_record_stopped_workflow(%State{run_spec: %RunSpec{lane: :workflow} = run_spec, run_id: run_id} = state, reason, finished_at)
       when is_binary(run_id) do
    WorkflowHistory.record_terminal_outcome(state.config, run_spec,
      run_id: run_id,
      outcome: :stopped,
      runtime_surface: state.runtime_surface,
      branch: state.branch,
      started_at: state.started_at,
      finished_at: finished_at,
      summary: stop_reason(reason),
      requested_action: RunSpec.requested_action(run_spec, state.config.failure_escalation_action),
      runtime_status: "paused",
      failure_kind: Atom.to_string(reason),
      error: reason
    )
  end

  defp maybe_record_stopped_workflow(_state, _reason, _finished_at), do: :ok

  defp maybe_generate_run_id(%RunSpec{lane: :workflow} = run_spec), do: WorkflowHistory.generate_run_id(run_spec)
  defp maybe_generate_run_id(_run_spec), do: nil

  defp maybe_put_runner_args(driver_opts, run_opts) do
    case Keyword.get(run_opts, :runner_args) do
      runner_args when is_list(runner_args) -> Keyword.put(driver_opts, :runner_args, runner_args)
      _ -> driver_opts
    end
  end

  defp lane_string(nil), do: nil
  defp lane_string(%RunSpec{} = spec), do: RunSpec.lane_string(spec)

  defp action_string(nil), do: nil
  defp action_string(%RunSpec{} = spec), do: RunSpec.action_string(spec)

  defp mode_string(nil), do: nil
  defp mode_string(%RunSpec{} = spec), do: RunSpec.runtime_mode(spec)

  defp workflow_name(nil), do: nil
  defp workflow_name(%RunSpec{workflow_name: workflow_name}), do: workflow_name

  defp workspace_kind(nil), do: "babysitter"
  defp workspace_kind(%RunSpec{} = spec), do: RunSpec.workspace_kind(spec)

  defp normalize_run_spec(%RunSpec{} = spec), do: {:ok, spec}
  defp normalize_run_spec(mode), do: RunSpec.checklist(mode)

  defp default_driver(_config, %RunSpec{lane: :workflow}), do: ForgeloopV2.WorkDrivers.ShellLoop

  defp default_driver(config, _run_spec) do
    if config.shell_driver_enabled, do: ForgeloopV2.WorkDrivers.ShellLoop, else: ForgeloopV2.WorkDrivers.Noop
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
