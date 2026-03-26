defmodule ForgeloopV2.SlotCoordinator.State do
  @moduledoc false

  defstruct [
    :config,
    :driver,
    :driver_opts,
    :started_at,
    :claim_id,
    slots: %{}
  ]
end

defmodule ForgeloopV2.SlotCoordinator.Record do
  @moduledoc false

  defstruct [
    :slot_id,
    :slot,
    :slot_config,
    :run_spec,
    :babysitter_pid,
    :babysitter_ref,
    :await_ref
  ]
end

defmodule ForgeloopV2.SlotCoordinator do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    ActiveRuntime,
    Babysitter,
    Config,
    Events,
    RunSpec,
    RuntimeStateStore,
    Slots,
    WorkflowHistory,
    Worktree
  }

  alias ForgeloopV2.SlotCoordinator.{Record, State}
  alias ForgeloopV2.Slots.Slot

  @active_statuses ~w(starting running stopping)
  @supported_surfaces ~w(ui openclaw service)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec list_slots(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def list_slots(server \\ __MODULE__), do: GenServer.call(server, :list_slots)

  @spec fetch_slot(GenServer.server(), String.t()) :: {:ok, map()} | :missing | {:error, term()}
  def fetch_slot(server \\ __MODULE__, slot_id), do: GenServer.call(server, {:fetch_slot, slot_id})

  @spec start_slot(GenServer.server(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def start_slot(server \\ __MODULE__, attrs), do: GenServer.call(server, {:start_slot, attrs}, :infinity)

  @spec stop_slot(GenServer.server(), String.t(), :pause | :kill | String.t()) ::
          {:ok, map()} | {:error, term()}
  def stop_slot(server \\ __MODULE__, slot_id, reason \\ :pause) do
    GenServer.call(server, {:stop_slot, slot_id, reason}, :infinity)
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        Process.flag(:trap_exit, true)
        :ok = Slots.mark_stale_runs(config)

        {:ok,
         %State{
           config: config,
           driver: Keyword.get(opts, :driver, default_driver(config)),
           driver_opts: Keyword.get(opts, :driver_opts, []),
           started_at: iso_now()
         }}

      _ ->
        case Config.load(opts) do
          {:ok, config} -> init(Keyword.put(opts, :config, config))
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    Enum.each(state.slots, fn {_slot_id, record} ->
      if is_pid(record.babysitter_pid) and Process.alive?(record.babysitter_pid) do
        Process.exit(record.babysitter_pid, :shutdown)
      end
    end)

    maybe_release_claim(state)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       started_at: state.started_at,
       claim_id: state.claim_id,
       active_slots: map_size(state.slots),
       max_read_slots: state.config.max_read_slots,
       max_write_slots: state.config.max_write_slots
     }, state}
  end

  def handle_call(:list_slots, _from, %State{} = state) do
    {:reply, {:ok, slot_collection(state.config)}, state}
  end

  def handle_call({:fetch_slot, slot_id}, _from, %State{} = state) do
    reply =
      case Slots.fetch(state.config, slot_id) do
        {:ok, slot} -> {:ok, Slots.detail(state.config, slot)}
        other -> other
      end

    {:reply, reply, state}
  end

  def handle_call({:start_slot, attrs}, _from, %State{} = state) do
    case do_start_slot(state, attrs) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:stop_slot, slot_id, reason}, _from, %State{} = state) do
    case do_stop_slot(state, slot_id, reason) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({ref, result}, %State{} = state) do
    case find_record_by_await_ref(state, ref) do
      nil ->
        {:noreply, state}

      %Record{} = record ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_slot(state, record, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case find_record_by_babysitter_ref(state, ref) || find_record_by_await_ref(state, ref) do
      nil ->
        {:noreply, state}

      %Record{} = record ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_slot(state, record, {:error, {:slot_process_down, reason}})}
    end
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp do_start_slot(%State{} = state, attrs) do
    with {:ok, request} <- normalize_start_attrs(attrs),
         :ok <- ensure_slot_action_allowed(request.run_spec),
         :ok <- ensure_start_gate(state),
         :ok <- ensure_slot_capacity(state, request.write_class),
         {:ok, next_state} <- ensure_claim(state),
         slot_id <- generate_slot_id(),
         :ok <- Slots.initialize_slot_files(next_state.config, slot_id),
         coordination_scope = coordination_scope_for(request.write_class),
         slot_config = Slots.slot_config(next_state.config, slot_id, coordination_scope),
         {:ok, pid} <-
           Babysitter.start_link(
             config: slot_config,
             run_spec: request.run_spec,
             branch: request.branch,
             runtime_surface: request.runtime_surface,
             driver: driver_for_run_spec(next_state.driver, request.run_spec),
             driver_opts: next_state.driver_opts,
             name: nil
           ),
         :ok <- Babysitter.start_run(pid, request.start_run_opts) do
      Process.unlink(pid)
      babysitter_ref = Process.monitor(pid)
      await_task = Task.Supervisor.async_nolink(ForgeloopV2.TaskSupervisor, fn -> Babysitter.await_result(pid, stop?: true) end)
      snapshot = Babysitter.snapshot(pid)

      slot =
        %Slot{
          slot_id: slot_id,
          lane: RunSpec.lane_string(request.run_spec),
          action: RunSpec.action_string(request.run_spec),
          mode: RunSpec.runtime_mode(request.run_spec),
          workflow_name: request.run_spec.workflow_name,
          branch: request.branch,
          ephemeral: request.ephemeral,
          write_class: request.write_class,
          coordination_scope: Atom.to_string(coordination_scope),
          status: if(snapshot.running?, do: "running", else: "starting"),
          runtime_surface: request.runtime_surface,
          worktree_path: snapshot.worktree_path,
          started_at: request.started_at,
          updated_at: request.started_at,
          run_id: request.run_id,
          last_result: nil,
          blocked_reason: nil
        }

      :ok = Slots.write(next_state.config, slot)

      Events.emit(next_state.config, :slot_started, %{
        "slot_id" => slot.slot_id,
        "lane" => slot.lane,
        "action" => slot.action,
        "mode" => slot.mode,
        "workflow_name" => slot.workflow_name,
        "branch" => slot.branch,
        "runtime_surface" => slot.runtime_surface,
        "write_class" => slot.write_class,
        "coordination_scope" => slot.coordination_scope,
        "worktree_path" => slot.worktree_path,
        "ephemeral" => slot.ephemeral
      })

      updated_state =
        put_in(next_state.slots[slot_id], %Record{
          slot_id: slot_id,
          slot: slot,
          slot_config: slot_config,
          run_spec: request.run_spec,
          babysitter_pid: pid,
          babysitter_ref: babysitter_ref,
          await_ref: await_task.ref
        })
        |> sync_root_runtime_summary()

      {:ok, slot_payload(updated_state.config, slot), updated_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_stop_slot(%State{} = state, slot_id, reason) do
    with {:ok, normalized_reason} <- normalize_stop_reason(reason),
         %Record{} = record <- Map.get(state.slots, slot_id),
         true <- is_pid(record.babysitter_pid) and Process.alive?(record.babysitter_pid) || {:error, :slot_not_running},
         :ok <- Babysitter.stop_child(record.babysitter_pid, normalized_reason) do
      updated_slot =
        record.slot
        |> Map.put(:status, "stopping")
        |> Map.put(:updated_at, iso_now())
        |> Map.put(:last_result, "stop_requested:#{normalized_reason}")

      :ok = Slots.write(state.config, updated_slot)

      Events.emit(state.config, :slot_stop_requested, %{
        "slot_id" => slot_id,
        "reason" => Atom.to_string(normalized_reason),
        "lane" => updated_slot.lane,
        "action" => updated_slot.action,
        "mode" => updated_slot.mode
      })

      next_state = put_in(state.slots[slot_id].slot, updated_slot)
      {:ok, slot_payload(next_state.config, updated_slot), next_state}
    else
      nil ->
        {:error, {:slot_not_found, slot_id}, state}

      {:error, reason} ->
        {:error, reason, state}

      false ->
        {:error, :slot_not_running, state}
    end
  end

  defp finish_slot(%State{} = state, %Record{} = record, result) do
    slot = finalize_slot_record(state.config, record.slot, result)
    _ = Slots.write(state.config, slot)

    event_type =
      case slot.status do
        "completed" -> :slot_completed
        "stopped" -> :slot_stopped
        "blocked" -> :slot_blocked
        "failed" -> :slot_failed
        _ -> :slot_updated
      end

    Events.emit(state.config, event_type, %{
      "slot_id" => slot.slot_id,
      "lane" => slot.lane,
      "action" => slot.action,
      "mode" => slot.mode,
      "workflow_name" => slot.workflow_name,
      "branch" => slot.branch,
      "status" => slot.status,
      "runtime_surface" => slot.runtime_surface,
      "last_result" => slot.last_result,
      "blocked_reason" => slot.blocked_reason
    })

    state
    |> remove_slot_record(record.slot_id)
    |> sync_root_runtime_summary()
  end

  defp finalize_slot_record(%Config{} = config, %Slot{} = slot, result) do
    hydrated_slot =
      case Slots.fetch(config, slot.slot_id) do
        {:ok, fetched} -> fetched
        _ -> slot
      end

    {status, last_result} =
      case result do
        {:ok, _payload} -> {"completed", "completed"}
        {:stopped, reason} -> {"stopped", format_result(reason)}
        {:retry, count} -> {"failed", "retry:#{count}"}
        {:error, reason} -> {"failed", format_result(reason)}
        other -> {hydrated_slot.status || "completed", format_result(other)}
      end

    reason_from_runtime =
      hydrated_slot.blocked_reason ||
        runtime_reason(config, hydrated_slot)

    status =
      cond do
        status == "completed" -> status
        hydrated_slot.status in ["blocked"] -> "blocked"
        reason_from_runtime not in [nil, ""] and status == "failed" -> "blocked"
        true -> status
      end

    hydrated_slot
    |> Map.put(:status, status)
    |> Map.put(:updated_at, iso_now())
    |> Map.put(:last_result, last_result)
    |> Map.put(:blocked_reason, reason_from_runtime)
  end

  defp slot_collection(%Config{} = config) do
    items = Slots.list(config)

    %{
      items: Enum.map(items, &slot_payload(config, &1)),
      counts: %{
        total: length(items),
        active: Enum.count(items, &(&1.status in @active_statuses)),
        blocked: Enum.count(items, &(&1.status == "blocked")),
        completed: Enum.count(items, &(&1.status == "completed")),
        failed: Enum.count(items, &(&1.status == "failed")),
        stopped: Enum.count(items, &(&1.status == "stopped"))
      },
      limits: %{
        read: config.max_read_slots,
        write: config.max_write_slots
      }
    }
  end

  defp slot_payload(%Config{} = config, %Slot{} = slot) do
    summary = Slots.summary(slot)

    Map.merge(summary, %{
      slot_paths: %{
        root: Slots.slot_dir(config, slot.slot_id),
        runtime_state: Slots.slot_runtime_state_path(config, slot.slot_id),
        coordination: Slots.slot_coordination_dir(config, slot.slot_id)
      }
    })
  end

  defp normalize_start_attrs(attrs) when is_list(attrs), do: normalize_start_attrs(Map.new(attrs))

  defp normalize_start_attrs(attrs) when is_map(attrs) do
    branch = blank_to_nil(Map.get(attrs, :branch) || Map.get(attrs, "branch"))
    runtime_surface = normalize_runtime_surface(Map.get(attrs, :runtime_surface) || Map.get(attrs, "runtime_surface") || Map.get(attrs, :surface) || Map.get(attrs, "surface") || "ui")
    ephemeral = truthy?(Map.get(attrs, :ephemeral) || Map.get(attrs, "ephemeral"), true)
    started_at = iso_now()

    with {:ok, run_spec, write_class} <- normalize_run_spec(attrs),
         {:ok, runtime_surface} <- runtime_surface do
      run_id =
        case run_spec do
          %RunSpec{lane: :workflow} -> WorkflowHistory.generate_run_id(run_spec)
          _ -> nil
        end

      {:ok,
       %{
         run_spec: run_spec,
         write_class: write_class,
         branch: branch,
         runtime_surface: runtime_surface,
         ephemeral: ephemeral,
         run_id: run_id,
         started_at: started_at,
         start_run_opts:
           [started_at: started_at]
           |> maybe_put_opt(:run_id, run_id)
       }}
    end
  end

  defp normalize_start_attrs(_attrs), do: {:error, :invalid_slot_request}

  defp normalize_run_spec(attrs) do
    lane = normalize_lane(Map.get(attrs, :lane) || Map.get(attrs, "lane"))
    action = normalize_action(Map.get(attrs, :action) || Map.get(attrs, "action") || Map.get(attrs, :mode) || Map.get(attrs, "mode"))
    workflow_name = blank_to_nil(Map.get(attrs, :workflow_name) || Map.get(attrs, "workflow_name") || Map.get(attrs, :workflowName) || Map.get(attrs, "workflowName"))

    case {lane, action} do
      {"checklist", "plan"} ->
        {:ok, %RunSpec{lane: :checklist, action: :plan, workflow_name: nil}, "read"}

      {"workflow", "preflight"} when is_binary(workflow_name) ->
        with {:ok, spec} <- RunSpec.workflow(:preflight, workflow_name) do
          {:ok, spec, "read"}
        end

      {"checklist", "build"} ->
        {:ok, %RunSpec{lane: :checklist, action: :build, workflow_name: nil}, "write"}

      {"workflow", "run"} when is_binary(workflow_name) ->
        with {:ok, spec} <- RunSpec.workflow(:run, workflow_name) do
          {:ok, spec, "write"}
        end

      {"workflow", _action} ->
        {:error, {:workflow_name_required, action}}

      {nil, _} ->
        {:error, :invalid_slot_lane}

      {_lane, nil} ->
        {:error, :invalid_slot_action}

      _ ->
        {:error, {:unsupported_slot_action, lane, action}}
    end
  end

  defp normalize_lane(nil), do: nil
  defp normalize_lane(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp normalize_action(nil), do: nil
  defp normalize_action(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp ensure_slot_action_allowed(%RunSpec{lane: :checklist, action: action}) when action in [:plan, :build], do: :ok
  defp ensure_slot_action_allowed(%RunSpec{lane: :workflow, action: action}) when action in [:preflight, :run], do: :ok
  defp ensure_slot_action_allowed(%RunSpec{} = spec), do: {:error, {:slot_action_deferred, RunSpec.lane_string(spec), RunSpec.action_string(spec)}}

  defp ensure_start_gate(%State{} = state) do
    with :ok <- ensure_runtime_owner_available(state.config),
         :ok <- ensure_active_run_available(state.config) do
      :ok
    end
  end

  defp ensure_runtime_owner_available(%Config{} = config) do
    case ActiveRuntime.status(config) do
      {:ok, %{live?: true, current: %{"owner" => "slots", "claim_id" => _claim_id}}} ->
        :ok

      {:ok, %{live?: true, current: current}} when is_map(current) ->
        {:error, {:active_runtime_owned_by, current}}

      {:ok, %{state: "error"} = status} ->
        {:error, {:active_runtime_state_error, status}}

      {:ok, _status} ->
        :ok
    end
  end

  defp ensure_active_run_available(%Config{} = config) do
    case Worktree.active_run_state(config) do
      :missing -> :ok
      {:stale, _payload} -> Worktree.cleanup_stale(config) |> then(fn _ -> :ok end)
      {:active, payload} -> {:error, {:babysitter_unmanaged_active, payload}}
      {:error, reason} -> {:error, {:active_run_state_error, reason}}
    end
  end

  defp ensure_slot_capacity(%State{} = state, "read") do
    active_read_count =
      state.slots
      |> Map.values()
      |> Enum.count(fn record -> record.slot.write_class == "read" end)

    if active_read_count < state.config.max_read_slots do
      :ok
    else
      {:error, {:slot_capacity_reached, :read, state.config.max_read_slots}}
    end
  end

  defp ensure_slot_capacity(%State{} = state, "write") do
    active_write_count =
      state.slots
      |> Map.values()
      |> Enum.count(fn record -> record.slot.write_class == "write" end)

    if active_write_count < state.config.max_write_slots do
      :ok
    else
      {:error, {:slot_capacity_reached, :write, state.config.max_write_slots}}
    end
  end

  defp ensure_claim(%State{claim_id: claim_id} = state) when is_binary(claim_id), do: {:ok, state}

  defp ensure_claim(%State{} = state) do
    case ActiveRuntime.claim(state.config, %{
           owner: "slots",
           surface: "service",
           mode: "slots",
           branch: state.config.default_branch
         }) do
      {:ok, claim} ->
        {:ok, %{state | claim_id: claim["claim_id"]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_slot_record(%State{} = state, slot_id) do
    next_state = %{state | slots: Map.delete(state.slots, slot_id)}

    if map_size(next_state.slots) == 0 do
      next_state
      |> maybe_release_claim()
      |> Map.put(:claim_id, nil)
    else
      next_state
    end
  end

  defp maybe_release_claim(%State{claim_id: claim_id} = state) when is_binary(claim_id) do
    _ = ActiveRuntime.release(state.config, claim_id)
    state
  end

  defp maybe_release_claim(%State{} = state), do: state

  defp sync_root_runtime_summary(%State{} = state) do
    payload =
      if map_size(state.slots) == 0 do
        %{
          status: "idle",
          transition: "completed",
          surface: "service",
          mode: "slots",
          reason: "No active slot runs",
          requested_action: "",
          branch: state.config.default_branch
        }
      else
        %{
          status: "running",
          transition: "coordinating",
          surface: "service",
          mode: "slots",
          reason: "Managing #{map_size(state.slots)} slot run(s)",
          requested_action: "",
          branch: state.config.default_branch
        }
      end

    _ = RuntimeStateStore.write(state.config, payload)
    state
  end

  defp runtime_reason(%Config{} = config, %Slot{} = slot) do
    slot_config = Slots.slot_config(config, slot.slot_id, coordination_scope_for_slot(slot))

    case RuntimeStateStore.read(slot_config) do
      {:ok, state} -> blank_to_nil(state.reason)
      _ -> nil
    end
  end

  defp find_record_by_await_ref(%State{} = state, ref) do
    Enum.find_value(state.slots, fn {_slot_id, record} ->
      if record.await_ref == ref, do: record, else: nil
    end)
  end

  defp find_record_by_babysitter_ref(%State{} = state, ref) do
    Enum.find_value(state.slots, fn {_slot_id, record} ->
      if record.babysitter_ref == ref, do: record, else: nil
    end)
  end

  defp normalize_runtime_surface(surface) when is_binary(surface) do
    normalized = surface |> String.trim() |> blank_to_nil()

    if normalized in @supported_surfaces do
      {:ok, normalized}
    else
      {:error, {:invalid_runtime_surface, surface}}
    end
  end

  defp normalize_runtime_surface(surface), do: {:error, {:invalid_runtime_surface, surface}}

  defp normalize_stop_reason(:pause), do: {:ok, :pause}
  defp normalize_stop_reason(:kill), do: {:ok, :kill}
  defp normalize_stop_reason("pause"), do: {:ok, :pause}
  defp normalize_stop_reason("kill"), do: {:ok, :kill}
  defp normalize_stop_reason(other), do: {:error, {:invalid_stop_reason, other}}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(nil, default), do: default
  defp truthy?(value, _default) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value, _default), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_result(value) when is_binary(value), do: value
  defp format_result(value), do: inspect(value)

  defp generate_slot_id do
    "slot-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp coordination_scope_for("write"), do: :canonical
  defp coordination_scope_for(_write_class), do: :slot_local

  defp coordination_scope_for_slot(%Slot{coordination_scope: "canonical"}), do: :canonical
  defp coordination_scope_for_slot(%Slot{write_class: "write"}), do: :canonical
  defp coordination_scope_for_slot(%Slot{}), do: :slot_local

  defp default_driver(config) do
    if config.shell_driver_enabled do
      ForgeloopV2.WorkDrivers.ShellLoop
    else
      ForgeloopV2.WorkDrivers.Noop
    end
  end

  defp driver_for_run_spec(ForgeloopV2.WorkDrivers.Noop, %RunSpec{lane: :workflow}),
    do: ForgeloopV2.WorkDrivers.ShellLoop

  defp driver_for_run_spec(driver, _run_spec), do: driver

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
