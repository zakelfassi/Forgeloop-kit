defmodule ForgeloopV2.ControlPlane.State do
  @moduledoc false

  defstruct [
    :config,
    :driver,
    :driver_opts,
    :started_at,
    :slot_coordinator_pid,
    :slot_coordinator_ref,
    :babysitter_pid,
    :babysitter_ref,
    :babysitter_run_spec,
    :babysitter_branch,
    :babysitter_runtime_surface,
    :last_action,
    :last_result
  ]
end

defmodule ForgeloopV2.ControlPlane do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    ActiveRuntime,
    Babysitter,
    Config,
    ControlFiles,
    Coordination,
    CoordinationAdvisor,
    Events,
    Orchestrator,
    PlanStore,
    ProviderHealth,
    RunSpec,
    RuntimeLifecycle,
    RuntimeStateStore,
    SlotCoordinator,
    ServiceOwnership,
    Tracker,
    WorkflowCatalog,
    WorkflowHistory,
    WorkflowService,
    Worktree
  }

  alias ForgeloopV2.ControlPlane.State

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec overview(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def overview(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:overview, opts}, :infinity)

  @spec runtime(GenServer.server()) ::
          {:ok, ForgeloopV2.RuntimeState.t() | nil} | {:error, term()}
  def runtime(server \\ __MODULE__), do: GenServer.call(server, :runtime)

  @spec backlog(GenServer.server()) :: {:ok, PlanStore.Backlog.t()} | {:error, term()}
  def backlog(server \\ __MODULE__), do: GenServer.call(server, :backlog)

  @spec questions(GenServer.server()) ::
          {:ok, [ForgeloopV2.Coordination.Question.t()]} | {:error, term()}
  def questions(server \\ __MODULE__), do: GenServer.call(server, :questions)

  @spec tracker(GenServer.server()) ::
          {:ok, ForgeloopV2.Tracker.RepoLocal.Overview.t()} | {:error, term()}
  def tracker(server \\ __MODULE__), do: GenServer.call(server, :tracker)

  @spec escalations(GenServer.server()) ::
          {:ok, [ForgeloopV2.Coordination.Escalation.t()]} | {:error, term()}
  def escalations(server \\ __MODULE__), do: GenServer.call(server, :escalations)

  @spec provider_health(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def provider_health(server \\ __MODULE__), do: GenServer.call(server, :provider_health)

  @spec events(GenServer.server(), keyword()) ::
          {:ok, %{items: [map()], meta: map()}} | {:error, term()}
  def events(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:events, opts})

  @spec coordination(GenServer.server(), keyword()) ::
          {:ok, ForgeloopV2.CoordinationAdvisor.Result.t()} | {:error, term()}
  def coordination(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:coordination, opts})

  @spec workflow_overview(GenServer.server(), keyword()) ::
          {:ok, ForgeloopV2.WorkflowService.Overview.t()} | {:error, term()}
  def workflow_overview(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:workflow_overview, opts})

  @spec workflow_fetch(GenServer.server(), String.t(), keyword()) ::
          {:ok, ForgeloopV2.WorkflowService.WorkflowSummary.t()} | :missing | {:error, term()}
  def workflow_fetch(server \\ __MODULE__, name, opts \\ []),
    do: GenServer.call(server, {:workflow_fetch, name, opts})

  @spec babysitter(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def babysitter(server \\ __MODULE__), do: GenServer.call(server, :babysitter)

  @spec ownership(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def ownership(server \\ __MODULE__), do: GenServer.call(server, :ownership)

  @spec slots(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def slots(server \\ __MODULE__), do: GenServer.call(server, :slots)

  @spec slot_fetch(GenServer.server(), String.t()) :: {:ok, map()} | :missing | {:error, term()}
  def slot_fetch(server \\ __MODULE__, slot_id), do: GenServer.call(server, {:slot_fetch, slot_id})

  @spec pause(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause, :infinity)

  @spec replan(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def replan(server \\ __MODULE__), do: GenServer.call(server, :replan, :infinity)

  @spec clear_pause(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def clear_pause(server \\ __MODULE__), do: GenServer.call(server, :clear_pause, :infinity)

  @spec answer_question(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def answer_question(server \\ __MODULE__, question_id, answer, opts \\ []) do
    GenServer.call(server, {:answer_question, question_id, answer, opts}, :infinity)
  end

  @spec resolve_question(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_question(server \\ __MODULE__, question_id, opts \\ []) do
    GenServer.call(server, {:resolve_question, question_id, opts}, :infinity)
  end

  @spec start_run(GenServer.server(), :plan | :build | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_run(server \\ __MODULE__, mode, opts \\ []) do
    GenServer.call(server, {:start_run, mode, opts}, :infinity)
  end

  @spec start_workflow(GenServer.server(), String.t(), :preflight | :run | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_workflow(server \\ __MODULE__, workflow_name, action, opts \\ []) do
    GenServer.call(server, {:start_workflow, workflow_name, action, opts}, :infinity)
  end

  @spec stop_run(GenServer.server(), :pause | :kill | String.t()) ::
          {:ok, map()} | {:error, term()}
  def stop_run(server \\ __MODULE__, reason \\ :pause) do
    GenServer.call(server, {:stop_run, reason}, :infinity)
  end

  @spec start_slot(GenServer.server(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def start_slot(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:start_slot, attrs}, :infinity)
  end

  @spec stop_slot(GenServer.server(), String.t(), :pause | :kill | String.t()) ::
          {:ok, map()} | {:error, term()}
  def stop_slot(server \\ __MODULE__, slot_id, reason \\ :pause) do
    GenServer.call(server, {:stop_slot, slot_id, reason}, :infinity)
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        with {:ok, slot_coordinator_pid, slot_coordinator_ref} <-
               start_slot_coordinator(config,
                 driver: Keyword.get(opts, :driver) || default_driver(config),
                 driver_opts: Keyword.get(opts, :driver_opts, [])
               ) do
          state = %State{
            config: config,
            driver: Keyword.get(opts, :driver) || default_driver(config),
            driver_opts: Keyword.get(opts, :driver_opts, []),
            started_at: iso_now(),
            slot_coordinator_pid: slot_coordinator_pid,
            slot_coordinator_ref: slot_coordinator_ref,
            last_action: nil,
            last_result: nil
          }

          Events.emit(config, :control_plane_started, %{
            "surface" => "service",
            "started_at" => state.started_at
          })

          {:ok, state}
        else
          {:error, reason} -> {:stop, reason}
        end

      _ ->
        case Config.load(opts) do
          {:ok, config} -> init(Keyword.put(opts, :config, config))
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %State{config: config, babysitter_pid: pid, slot_coordinator_pid: slot_pid}) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    if is_pid(slot_pid) and Process.alive?(slot_pid) do
      Process.exit(slot_pid, :shutdown)
    end

    Events.emit(config, :control_plane_stopped, %{
      "surface" => "service",
      "stopped_at" => iso_now()
    })

    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       started_at: state.started_at,
       last_action: state.last_action,
       last_result: state.last_result,
       slot_coordinator_started?: is_pid(state.slot_coordinator_pid),
       babysitter_mode: mode_from_run_spec(state.babysitter_run_spec),
       babysitter_branch: state.babysitter_branch,
       babysitter_runtime_surface: state.babysitter_runtime_surface
     }, state}
  end

  def handle_call({:overview, opts}, _from, %State{} = state) do
    case read_slots(state) do
      {:ok, slots, next_state} ->
        reply =
          with {:ok, runtime_state} <- read_runtime_state(next_state.config),
               {:ok, runtime_owner} <- read_runtime_owner(next_state.config),
               {:ok, backlog} <- read_backlog(next_state.config),
               {:ok, control_flags} <- read_control_flags(next_state.config),
               {:ok, questions} <- read_questions(next_state.config),
               {:ok, escalations} <- read_escalations(next_state.config),
               {:ok, provider_health} <- read_provider_health(next_state.config),
               {:ok, workflow_overview} <- WorkflowService.overview(next_state.config),
               {:ok, tracker} <- read_tracker(next_state.config, backlog, workflow_overview),
               {:ok, event_result} <- read_events(next_state.config, opts),
               {:ok, babysitter} <-
                 babysitter_status(next_state, Keyword.get(opts, :include_active_run?, true)),
               {:ok, coordination} <-
                 evaluate_coordination(
                   %{
                     runtime_state: runtime_state,
                     backlog: backlog,
                     control_flags: control_flags,
                     questions: questions,
                     babysitter: babysitter,
                     events: event_result.items,
                     events_meta: event_result.meta
                   },
                   opts
                 ) do
            ownership = build_ownership(runtime_owner, babysitter)

            {:ok,
             %{
               runtime_state: runtime_state,
               runtime_owner: runtime_owner_state(runtime_owner, ownership),
               ownership: ownership,
               backlog: backlog,
               control_flags: control_flags,
               tracker: tracker,
               questions: questions,
               escalations: escalations,
               provider_health: provider_health,
               events: event_result.items,
               events_meta: event_result.meta,
               coordination: coordination,
               workflows: workflow_overview,
               babysitter: babysitter,
               slots: slots
             }}
          end

        {:reply, reply, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:runtime, _from, %State{} = state) do
    {:reply, read_runtime_state(state.config), state}
  end

  def handle_call(:backlog, _from, %State{} = state) do
    {:reply, read_backlog(state.config), state}
  end

  def handle_call(:questions, _from, %State{} = state) do
    {:reply, read_questions(state.config), state}
  end

  def handle_call(:tracker, _from, %State{} = state) do
    {:reply, read_tracker(state.config), state}
  end

  def handle_call(:escalations, _from, %State{} = state) do
    {:reply, read_escalations(state.config), state}
  end

  def handle_call(:provider_health, _from, %State{} = state) do
    {:reply, read_provider_health(state.config), state}
  end

  def handle_call({:events, opts}, _from, %State{} = state) do
    {:reply, read_events(state.config, opts), state}
  end

  def handle_call({:coordination, opts}, _from, %State{} = state) do
    {:reply, read_coordination_snapshot(state, opts), state}
  end

  def handle_call({:workflow_overview, opts}, _from, %State{} = state) do
    {:reply, WorkflowService.overview(state.config, opts), state}
  end

  def handle_call({:workflow_fetch, name, opts}, _from, %State{} = state) do
    {:reply, WorkflowService.fetch(state.config, name, opts), state}
  end

  def handle_call(:babysitter, _from, %State{} = state) do
    {:reply, babysitter_status(state, true), state}
  end

  def handle_call(:ownership, _from, %State{} = state) do
    reply =
      with {:ok, runtime_owner} <- read_runtime_owner(state.config),
           {:ok, babysitter} <- babysitter_status(state, true) do
        {:ok, build_ownership(runtime_owner, babysitter)}
      end

    {:reply, reply, state}
  end

  def handle_call(:slots, _from, %State{} = state) do
    case read_slots(state) do
      {:ok, slots, next_state} -> {:reply, {:ok, slots}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:slot_fetch, slot_id}, _from, %State{} = state) do
    case ensure_slot_coordinator_instance(state) do
      {:ok, next_state, pid} -> {:reply, SlotCoordinator.fetch_slot(pid, slot_id), next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, %State{} = state) do
    case do_pause(state) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(:replan, _from, %State{} = state) do
    case ControlFiles.append_flag(state.config, "REPLAN") do
      :ok ->
        Events.emit(state.config, :operator_action, %{
          "surface" => "service",
          "action" => "replan_requested",
          "recorded_at" => iso_now()
        })

        {:reply, {:ok, %{requested?: true}}, %{state | last_action: :replan, last_result: :ok}}

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | last_action: :replan_failed, last_result: {:error, reason}}}
    end
  end

  def handle_call(:clear_pause, _from, %State{} = state) do
    case do_clear_pause(state) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:answer_question, question_id, answer, opts}, _from, %State{} = state) do
    case ControlFiles.answer_question(state.config, question_id, answer, opts) do
      {:ok, result} ->
        Events.emit(state.config, :operator_action, %{
          "surface" => "service",
          "action" => "answer_question",
          "question_id" => question_id,
          "recorded_at" => iso_now()
        })

        {:reply, {:ok, result}, %{state | last_action: :answer_question, last_result: :ok}}

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | last_action: :answer_question_failed, last_result: {:error, reason}}}
    end
  end

  def handle_call({:resolve_question, question_id, opts}, _from, %State{} = state) do
    case ControlFiles.resolve_question(state.config, question_id, opts) do
      {:ok, result} ->
        Events.emit(state.config, :operator_action, %{
          "surface" => "service",
          "action" => "resolve_question",
          "question_id" => question_id,
          "recorded_at" => iso_now()
        })

        {:reply, {:ok, result}, %{state | last_action: :resolve_question, last_result: :ok}}

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | last_action: :resolve_question_failed, last_result: {:error, reason}}}
    end
  end

  def handle_call({:start_run, mode, opts}, _from, %State{} = state) do
    case do_start_run(state, mode, opts) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:start_workflow, workflow_name, action, opts}, _from, %State{} = state) do
    case do_start_workflow(state, workflow_name, action, opts) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:stop_run, reason}, _from, %State{} = state) do
    case do_stop_run(state, reason) do
      {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:start_slot, attrs}, _from, %State{} = state) do
    case ensure_slot_coordinator_instance(state) do
      {:ok, next_state, pid} ->
        case SlotCoordinator.start_slot(pid, attrs) do
          {:ok, payload} ->
            {:reply, {:ok, payload},
             %{next_state | last_action: :start_slot, last_result: :ok}}

          {:error, reason} ->
            {:reply, {:error, reason},
             %{next_state | last_action: :start_slot_failed, last_result: {:error, reason}}}
        end

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | last_action: :start_slot_failed, last_result: {:error, reason}}}
    end
  end

  def handle_call({:stop_slot, slot_id, reason}, _from, %State{} = state) do
    case ensure_slot_coordinator_instance(state) do
      {:ok, next_state, pid} ->
        case SlotCoordinator.stop_slot(pid, slot_id, reason) do
          {:ok, payload} ->
            {:reply, {:ok, payload},
             %{next_state | last_action: {:stop_slot, slot_id}, last_result: :ok}}

          {:error, stop_reason} ->
            {:reply, {:error, stop_reason},
             %{next_state | last_action: :stop_slot_failed, last_result: {:error, stop_reason}}}
        end

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | last_action: :stop_slot_failed, last_result: {:error, reason}}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{slot_coordinator_ref: ref} = state) do
    next_state =
      state
      |> Map.put(:slot_coordinator_pid, nil)
      |> Map.put(:slot_coordinator_ref, nil)
      |> Map.put(:last_result, {:slot_coordinator_down, reason})
      |> Map.put(:last_action, :slot_coordinator_down)

    {:noreply, next_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{babysitter_ref: ref} = state) do
    next_state =
      clear_babysitter(state)
      |> Map.put(:last_result, {:babysitter_down, reason})
      |> Map.put(:last_action, :babysitter_down)

    {:noreply, next_state}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp do_pause(%State{} = state) do
    with :ok <- ControlFiles.append_flag(state.config, "PAUSE"),
         {:ok, running_snapshot} <- babysitter_status(state, true),
         :ok <- maybe_pause_runtime(state.config, running_snapshot),
         :ok <- maybe_stop_managed_babysitter(state, running_snapshot),
         {:ok, updated_snapshot} <- babysitter_status(state, true) do
      Events.emit(state.config, :operator_action, %{
        "surface" => "service",
        "action" => "pause_requested",
        "recorded_at" => iso_now()
      })

      {:ok, %{requested?: true, babysitter: updated_snapshot},
       %{state | last_action: :pause, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :pause_failed, last_result: {:error, reason}}}
    end
  end

  defp do_clear_pause(%State{} = state) do
    pause_requested? = ControlFiles.has_flag?(state.config, "PAUSE")

    case ControlFiles.consume_flag(state.config, "PAUSE") do
      :ok ->
        Events.emit(state.config, :operator_action, %{
          "surface" => "service",
          "action" => "clear_pause",
          "recorded_at" => iso_now()
        })

        {:ok, %{cleared?: pause_requested?, pause_requested?: false},
         %{state | last_action: :clear_pause, last_result: :ok}}

      {:error, reason} ->
        {:error, reason,
         %{state | last_action: :clear_pause_failed, last_result: {:error, reason}}}
    end
  end

  defp do_start_run(%State{} = state, mode, opts) do
    with {:ok, normalized_mode} <- normalize_mode(mode),
         {:ok, run_spec} <- RunSpec.checklist(normalized_mode),
         {:ok, runtime_surface} <-
           normalize_runtime_surface(Keyword.get(opts, :runtime_surface, "babysitter")),
         {:ok, ownership} <- start_gate_snapshot(state),
         :ok <- ensure_start_allowed(ownership),
         {:ok, payload, next_state} <-
           do_start_managed_run(state, run_spec, runtime_surface, opts) do
      {:ok, payload, %{next_state | last_action: {:start_run, normalized_mode}, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :start_run_failed, last_result: {:error, reason}}}
    end
  end

  defp do_start_workflow(%State{} = state, workflow_name, action, opts) do
    with {:ok, run_spec} <- normalize_workflow_run_spec(action, workflow_name),
         {:ok, runtime_surface} <-
           normalize_runtime_surface(Keyword.get(opts, :runtime_surface, "workflow")),
         {:ok, runner_args} <- normalize_runner_args(Keyword.get(opts, :runner_args, [])),
         {:ok, ownership} <- start_gate_snapshot(state),
         :ok <- ensure_start_allowed(ownership),
         :ok <- ensure_workflow_exists(state.config, workflow_name) do
      run_opts =
        workflow_start_opts(
          run_spec,
          runtime_surface,
          Keyword.put(opts, :runner_args, runner_args)
        )

      case do_start_managed_run(state, run_spec, runtime_surface, run_opts) do
        {:ok, payload, next_state} ->
          {:ok, payload,
           %{next_state | last_action: {:start_workflow, action, workflow_name}, last_result: :ok}}

        {:error, reason, next_state} ->
          _ =
            record_workflow_start_failure(
              state.config,
              run_spec,
              run_opts,
              runtime_surface,
              reason
            )

          {:error, reason,
           %{next_state | last_action: :start_workflow_failed, last_result: {:error, reason}}}
      end
    else
      {:error, reason} ->
        {:error, reason,
         %{state | last_action: :start_workflow_failed, last_result: {:error, reason}}}
    end
  end

  defp do_start_managed_run(%State{} = state, %RunSpec{} = run_spec, runtime_surface, opts) do
    with {:ok, next_state, pid} <-
           ensure_babysitter_instance(state, run_spec, runtime_surface, opts),
         :ok <- Babysitter.start_run(pid, start_run_opts(opts)),
         {:ok, updated_babysitter} <- babysitter_status(next_state, true) do
      Events.emit(state.config, :operator_action, %{
        "surface" => "service",
        "action" => if(run_spec.lane == :workflow, do: "start_workflow", else: "start_run"),
        "lane" => RunSpec.lane_string(run_spec),
        "mode" => RunSpec.runtime_mode(run_spec),
        "workflow_name" => run_spec.workflow_name,
        "runtime_surface" => runtime_surface,
        "recorded_at" => iso_now()
      })

      {:ok,
       %{
         lane: RunSpec.lane_string(run_spec),
         action: RunSpec.action_string(run_spec),
         mode: RunSpec.runtime_mode(run_spec),
         workflow: run_spec.workflow_name,
         surface: runtime_surface,
         babysitter: updated_babysitter
       }, next_state}
    end
  end

  defp do_stop_run(%State{} = state, reason) do
    with {:ok, normalized_reason} <- normalize_stop_reason(reason),
         {:ok, babysitter} <- babysitter_status(state, true),
         {:ok, pid} <- managed_babysitter_pid(state),
         true <- babysitter.running? || {:error, :babysitter_not_running},
         :ok <- Babysitter.stop_child(pid, normalized_reason),
         {:ok, updated_babysitter} <- babysitter_status(state, true) do
      Events.emit(state.config, :operator_action, %{
        "surface" => "service",
        "action" => "stop_run",
        "reason" => Atom.to_string(normalized_reason),
        "recorded_at" => iso_now()
      })

      {:ok, %{stopped?: true, babysitter: updated_babysitter},
       %{state | last_action: {:stop_run, normalized_reason}, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :stop_run_failed, last_result: {:error, reason}}}

      false ->
        {:error, :babysitter_not_running,
         %{state | last_action: :stop_run_failed, last_result: {:error, :babysitter_not_running}}}
    end
  end

  defp read_runtime_state(config) do
    case RuntimeStateStore.read(config) do
      {:ok, state} -> {:ok, state}
      :missing -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_runtime_owner(config), do: ActiveRuntime.status(config)

  defp read_backlog(config), do: PlanStore.summary(config)

  defp read_tracker(config) do
    with {:ok, backlog} <- read_backlog(config),
         {:ok, workflow_overview} <- WorkflowService.overview(config) do
      read_tracker(config, backlog, workflow_overview)
    end
  end

  defp read_tracker(config, backlog, workflow_overview) do
    Tracker.Service.repo_local_overview(config, backlog, workflow_overview)
  end

  defp read_slots(%State{} = state) do
    case ensure_slot_coordinator_instance(state) do
      {:ok, next_state, pid} ->
        case SlotCoordinator.list_slots(pid) do
          {:ok, slots} -> {:ok, slots, next_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_control_flags(config) do
    workflow_request = Orchestrator.workflow_request(config)
    workflow_run_spec = workflow_request.run_spec

    {:ok,
     %{
       pause_requested?: ControlFiles.has_flag?(config, "PAUSE"),
       replan_requested?: ControlFiles.has_flag?(config, "REPLAN"),
       deploy_requested?: ControlFiles.has_flag?(config, "DEPLOY"),
       ingest_logs_requested?: ControlFiles.has_flag?(config, "INGEST_LOGS"),
       workflow_requested?: workflow_request.requested?,
       workflow_target: %{
         configured?:
           is_binary(config.daemon_workflow_name) and config.daemon_workflow_name != "",
         valid?: match?(%RunSpec{}, workflow_run_spec),
         name: config.daemon_workflow_name,
         action: config.daemon_workflow_action,
         mode:
           if(match?(%RunSpec{}, workflow_run_spec),
             do: RunSpec.runtime_mode(workflow_run_spec),
             else: nil
           ),
         error: workflow_request_error_code(workflow_request.error)
       }
     }}
  end

  defp read_questions(config) do
    case Coordination.read_questions(config) do
      {:ok, questions} -> {:ok, questions}
      :missing -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_escalations(config) do
    case Coordination.read_escalations(config) do
      {:ok, escalations} -> {:ok, escalations}
      :missing -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_provider_health(config), do: {:ok, ProviderHealth.read(config)}

  defp read_events(config, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> normalize_limit()

    case normalize_after_cursor(Keyword.get(opts, :after)) do
      nil -> Events.tail(config, limit: limit)
      cursor -> Events.replay(config, after: cursor, limit: limit)
    end
  end

  defp read_coordination_snapshot(%State{} = state, opts) do
    with {:ok, runtime_state} <- read_runtime_state(state.config),
         {:ok, backlog} <- read_backlog(state.config),
         {:ok, control_flags} <- read_control_flags(state.config),
         {:ok, questions} <- read_questions(state.config),
         {:ok, event_result} <- read_events(state.config, opts),
         {:ok, babysitter} <-
           babysitter_status(state, Keyword.get(opts, :include_active_run?, true)) do
      evaluate_coordination(
        %{
          runtime_state: runtime_state,
          backlog: backlog,
          control_flags: control_flags,
          questions: questions,
          babysitter: babysitter,
          events: event_result.items,
          events_meta: event_result.meta
        },
        opts
      )
    end
  end

  defp evaluate_coordination(snapshot, opts) when is_map(snapshot) do
    with {:ok, playbook_id} <- normalize_coordination_playbook_id(opts) do
      CoordinationAdvisor.evaluate_snapshot(snapshot,
        after: Keyword.get(opts, :after),
        playbook_id: playbook_id
      )
    end
  end

  defp normalize_coordination_playbook_id(opts) do
    provided? = Keyword.get(opts, :playbook_provided?, false)
    raw_playbook_id = Keyword.get(opts, :playbook_id)

    cond do
      not provided? and is_nil(raw_playbook_id) ->
        {:ok, nil}

      is_binary(raw_playbook_id) ->
        normalized = String.trim(raw_playbook_id)

        if normalized in CoordinationAdvisor.playbook_ids() do
          {:ok, normalized}
        else
          {:error, {:invalid_coordination_playbook, raw_playbook_id}}
        end

      true ->
        {:error, {:invalid_coordination_playbook, raw_playbook_id}}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} when int > 0 -> min(int, 500)
      _ -> 50
    end
  end

  defp normalize_limit(_), do: 50

  defp normalize_after_cursor(nil), do: nil

  defp normalize_after_cursor(cursor) when is_binary(cursor) do
    case String.trim(cursor) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_after_cursor(_), do: nil

  defp babysitter_status(%State{} = state, include_active_run?) do
    managed_snapshot =
      case state.babysitter_pid do
        pid when is_pid(pid) -> if(Process.alive?(pid), do: Babysitter.snapshot(pid), else: nil)
        _ -> nil
      end

    active_run_status = active_run_status(state.config, include_active_run?)
    active_run = active_run_status.payload

    {:ok,
     %{
       managed?: not is_nil(managed_snapshot),
       lane: lane_from_run_spec(state.babysitter_run_spec) || Map.get(active_run || %{}, "lane"),
       action:
         action_from_run_spec(state.babysitter_run_spec) || Map.get(active_run || %{}, "action"),
       mode: mode_from_run_spec(state.babysitter_run_spec) || Map.get(active_run || %{}, "mode"),
       workflow_name:
         workflow_name_from_run_spec(state.babysitter_run_spec) ||
           Map.get(active_run || %{}, "workflow_name"),
       branch: state.babysitter_branch || Map.get(active_run || %{}, "branch"),
       runtime_surface:
         state.babysitter_runtime_surface ||
           (managed_snapshot && managed_snapshot.runtime_surface) ||
           Map.get(active_run || %{}, "runtime_surface"),
       snapshot: managed_snapshot,
       active_run_state: active_run_status.state,
       active_run_error: active_run_status.error,
       active_run: active_run,
       running?: babysitter_running?(managed_snapshot, active_run_status)
     }}
  end

  defp active_run_status(_config, false), do: %{state: "missing", payload: nil, error: nil}

  defp active_run_status(config, true) do
    case Worktree.active_run_state(config) do
      :missing ->
        %{state: "missing", payload: nil, error: nil}

      {:active, payload} ->
        %{state: "active", payload: payload, error: nil}

      {:stale, payload} ->
        %{state: "stale", payload: payload, error: nil}

      {:error, reason} ->
        %{state: "error", payload: nil, error: "invalid_active_run: #{inspect(reason)}"}
    end
  end

  defp babysitter_running?(%{running?: true}, _active_run_status), do: true
  defp babysitter_running?(_managed_snapshot, %{state: "active"}), do: true
  defp babysitter_running?(_, _), do: false

  defp maybe_pause_runtime(_config, %{running?: true, managed?: false}), do: :ok
  defp maybe_pause_runtime(_config, %{active_run_state: "active"}), do: :ok

  defp maybe_pause_runtime(config, _babysitter) do
    case RuntimeStateStore.status(config) do
      status when status in ["running", "paused", "awaiting-human"] ->
        :ok

      _ ->
        case RuntimeLifecycle.transition(config, :paused_by_operator, :service, %{
               surface: "service",
               mode: "service",
               reason: "Paused via loopback control plane",
               requested_action: "",
               branch: config.default_branch
             }) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_stop_managed_babysitter(%State{} = state, %{snapshot: %{running?: true}}) do
    case managed_babysitter_pid(state) do
      {:ok, pid} -> Babysitter.stop_child(pid, :pause)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_stop_managed_babysitter(_state, _babysitter), do: :ok

  defp start_gate_snapshot(%State{} = state) do
    with {:ok, runtime_owner} <- read_runtime_owner(state.config),
         {:ok, babysitter} <- babysitter_status(state, true),
         {:ok, refreshed_runtime_owner, refreshed_babysitter} <-
           maybe_cleanup_stale_start_state(state, runtime_owner, babysitter) do
      {:ok, build_ownership(refreshed_runtime_owner, refreshed_babysitter)}
    end
  end

  defp maybe_cleanup_stale_start_state(
         %State{} = state,
         _runtime_owner,
         %{active_run_state: "stale"}
       ) do
    with {:ok, _cleaned} <- Worktree.cleanup_stale(state.config),
         {:ok, refreshed_runtime_owner} <- read_runtime_owner(state.config),
         {:ok, refreshed_babysitter} <- babysitter_status(state, true) do
      case refreshed_babysitter.active_run_state do
        "stale" -> {:error, {:active_run_state_error, :stale_active_run_persisted}}
        _ -> {:ok, refreshed_runtime_owner, refreshed_babysitter}
      end
    else
      {:error, reason} -> {:error, {:active_run_state_error, reason}}
    end
  end

  defp maybe_cleanup_stale_start_state(%State{}, runtime_owner, babysitter),
    do: {:ok, runtime_owner, babysitter}

  defp ensure_start_allowed(%{gate_error: nil}), do: :ok
  defp ensure_start_allowed(%{gate_error: gate_error}), do: {:error, gate_error}

  defp ensure_babysitter_instance(%State{} = state, %RunSpec{} = run_spec, runtime_surface, opts) do
    branch = opts[:branch] || state.config.default_branch

    cond do
      reusable_babysitter?(state, run_spec, branch, runtime_surface) ->
        {:ok, state, state.babysitter_pid}

      is_pid(state.babysitter_pid) ->
        if Process.alive?(state.babysitter_pid) do
          Process.exit(state.babysitter_pid, :shutdown)
        end

        start_babysitter(state, run_spec, branch, runtime_surface)

      true ->
        start_babysitter(state, run_spec, branch, runtime_surface)
    end
  end

  defp start_babysitter(%State{} = state, %RunSpec{} = run_spec, branch, runtime_surface) do
    case Babysitter.start_link(
           config: state.config,
           run_spec: run_spec,
           branch: branch,
           runtime_surface: runtime_surface,
           driver: driver_for_run_spec(state.driver, run_spec),
           driver_opts: state.driver_opts,
           name: nil
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        ref = Process.monitor(pid)

        {:ok,
         %{
           state
           | babysitter_pid: pid,
             babysitter_ref: ref,
             babysitter_run_spec: run_spec,
             babysitter_branch: branch,
             babysitter_runtime_surface: runtime_surface
         }, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reusable_babysitter?(
         %State{
           babysitter_pid: pid,
           babysitter_run_spec: run_spec,
           babysitter_branch: branch,
           babysitter_runtime_surface: runtime_surface
         },
         %RunSpec{} = requested_spec,
         branch,
         runtime_surface
       )
       when is_pid(pid) do
    Process.alive?(pid) and RunSpec.same_instance?(run_spec, requested_spec)
  end

  defp reusable_babysitter?(_, _, _, _), do: false

  defp driver_for_run_spec(ForgeloopV2.WorkDrivers.Noop, %RunSpec{lane: :workflow}),
    do: ForgeloopV2.WorkDrivers.ShellLoop

  defp driver_for_run_spec(driver, _run_spec), do: driver

  defp managed_babysitter_pid(%State{babysitter_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :babysitter_not_managed}
  end

  defp managed_babysitter_pid(_state), do: {:error, :babysitter_not_managed}

  defp clear_babysitter(%State{} = state) do
    %{
      state
      | babysitter_pid: nil,
        babysitter_ref: nil,
        babysitter_run_spec: nil,
        babysitter_branch: nil,
        babysitter_runtime_surface: nil
    }
  end

  defp normalize_mode(:plan), do: {:ok, :plan}
  defp normalize_mode(:build), do: {:ok, :build}
  defp normalize_mode("plan"), do: {:ok, :plan}
  defp normalize_mode("build"), do: {:ok, :build}
  defp normalize_mode(other), do: {:error, {:invalid_mode, other}}

  defp normalize_workflow_run_spec(action, workflow_name) do
    with {:ok, normalized_action} <- normalize_workflow_action(action) do
      RunSpec.workflow(normalized_action, workflow_name)
    end
  end

  defp normalize_workflow_action(:preflight), do: {:ok, :preflight}
  defp normalize_workflow_action(:run), do: {:ok, :run}
  defp normalize_workflow_action("preflight"), do: {:ok, :preflight}
  defp normalize_workflow_action("run"), do: {:ok, :run}
  defp normalize_workflow_action(other), do: {:error, {:invalid_workflow_action, other}}

  defp normalize_runner_args(nil), do: {:ok, []}
  defp normalize_runner_args([]), do: {:ok, []}

  defp normalize_runner_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, {:invalid_runner_args, args}}
    end
  end

  defp normalize_runner_args(other), do: {:error, {:invalid_runner_args, other}}

  defp normalize_runtime_surface("ui"), do: {:ok, "ui"}
  defp normalize_runtime_surface("openclaw"), do: {:ok, "openclaw"}
  defp normalize_runtime_surface("babysitter"), do: {:ok, "babysitter"}
  defp normalize_runtime_surface("workflow"), do: {:ok, "workflow"}
  defp normalize_runtime_surface(other), do: {:error, {:invalid_runtime_surface, other}}

  defp normalize_stop_reason(:pause), do: {:ok, :pause}
  defp normalize_stop_reason(:kill), do: {:ok, :kill}
  defp normalize_stop_reason("pause"), do: {:ok, :pause}
  defp normalize_stop_reason("kill"), do: {:ok, :kill}
  defp normalize_stop_reason(other), do: {:error, {:invalid_stop_reason, other}}

  defp start_run_opts(opts) do
    []
    |> maybe_put_start_opt(:runner_args, Keyword.get(opts, :runner_args))
    |> maybe_put_start_opt(:run_id, Keyword.get(opts, :run_id))
    |> maybe_put_start_opt(:started_at, Keyword.get(opts, :started_at))
  end

  defp workflow_start_opts(%RunSpec{} = run_spec, runtime_surface, opts) do
    opts
    |> Keyword.put_new(:run_id, WorkflowHistory.generate_run_id(run_spec))
    |> Keyword.put_new(:started_at, iso_now())
    |> Keyword.put(:runtime_surface, runtime_surface)
  end

  defp record_workflow_start_failure(
         %Config{} = config,
         %RunSpec{} = run_spec,
         opts,
         runtime_surface,
         reason
       ) do
    WorkflowHistory.record_terminal_outcome(config, run_spec,
      run_id: Keyword.fetch!(opts, :run_id),
      outcome: :start_failed,
      runtime_surface: runtime_surface,
      branch: Keyword.get(opts, :branch, config.default_branch),
      started_at: Keyword.get(opts, :started_at),
      finished_at: iso_now(),
      summary:
        "Managed #{RunSpec.runtime_mode(run_spec)} failed before loop start: #{inspect(reason)}",
      requested_action: RunSpec.requested_action(run_spec, config.failure_escalation_action),
      runtime_status: nil,
      failure_kind: RunSpec.runtime_mode(run_spec),
      error: reason
    )
  end

  defp maybe_put_start_opt(opts, _key, nil), do: opts
  defp maybe_put_start_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_workflow_exists(config, workflow_name) do
    case WorkflowCatalog.fetch(config, workflow_name) do
      {:ok, _entry} -> :ok
      :missing -> {:error, {:workflow_not_found, workflow_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lane_from_run_spec(nil), do: nil
  defp lane_from_run_spec(%RunSpec{} = run_spec), do: RunSpec.lane_string(run_spec)

  defp action_from_run_spec(nil), do: nil
  defp action_from_run_spec(%RunSpec{} = run_spec), do: RunSpec.action_string(run_spec)

  defp mode_from_run_spec(nil), do: nil
  defp mode_from_run_spec(%RunSpec{} = run_spec), do: RunSpec.runtime_mode(run_spec)

  defp workflow_name_from_run_spec(nil), do: nil
  defp workflow_name_from_run_spec(%RunSpec{} = run_spec), do: run_spec.workflow_name

  defp workflow_request_error_code(nil), do: nil

  defp workflow_request_error_code(:missing_daemon_workflow_name),
    do: "missing_daemon_workflow_name"

  defp workflow_request_error_code({:invalid_daemon_workflow_action, _value}),
    do: "invalid_daemon_workflow_action"

  defp workflow_request_error_code({:invalid_workflow_name, _workflow_name}),
    do: "invalid_workflow_name"

  defp workflow_request_error_code(reason), do: inspect(reason)

  defp default_driver(config) do
    if config.shell_driver_enabled do
      ForgeloopV2.WorkDrivers.ShellLoop
    else
      ForgeloopV2.WorkDrivers.Noop
    end
  end

  defp start_slot_coordinator(%Config{} = config, opts) do
    case SlotCoordinator.start_link(
           config: config,
           driver: Keyword.get(opts, :driver),
           driver_opts: Keyword.get(opts, :driver_opts, []),
           name: nil
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid, Process.monitor(pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_slot_coordinator_instance(%State{slot_coordinator_pid: pid} = state)
       when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, state, pid}
    else
      ensure_slot_coordinator_instance(%{state | slot_coordinator_pid: nil, slot_coordinator_ref: nil})
    end
  end

  defp ensure_slot_coordinator_instance(%State{} = state) do
    with {:ok, pid, ref} <-
           start_slot_coordinator(state.config,
             driver: state.driver,
             driver_opts: state.driver_opts
           ) do
      next_state = %{state | slot_coordinator_pid: pid, slot_coordinator_ref: ref}
      {:ok, next_state, pid}
    end
  end

  defp runtime_owner_state(runtime_owner, ownership) do
    Map.put(runtime_owner, :start_allowed?, ownership.start_allowed?)
  end

  defp build_ownership(runtime_owner, babysitter) do
    ServiceOwnership.evaluate(runtime_owner, babysitter)
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end

defmodule ForgeloopV2.ServiceJSON do
  @moduledoc false

  alias ForgeloopV2.Coordination.{Escalation, Question}
  alias ForgeloopV2.CoordinationAdvisor

  alias ForgeloopV2.CoordinationAdvisor.{
    Cursor,
    Playbook,
    PlaybookCounts,
    Recommendation,
    Result,
    Summary,
    TimelineEntry
  }

  alias ForgeloopV2.PlanStore
  alias ForgeloopV2.PlanStore.Item
  alias ForgeloopV2.RuntimeState
  alias ForgeloopV2.Tracker.Issue
  alias ForgeloopV2.Tracker.RepoLocal.Overview, as: TrackerOverview
  alias ForgeloopV2.WorkflowCatalog.Entry, as: WorkflowCatalogEntry
  alias ForgeloopV2.WorkflowHistory.{Entry, Snapshot}
  alias ForgeloopV2.WorkflowService.{ActionSnapshot, ActiveRun, Overview, WorkflowSummary}

  @spec overview(map()) :: map()
  def overview(payload) do
    %{
      runtime_state: runtime_state(payload.runtime_state),
      runtime_owner: runtime_owner(payload.runtime_owner),
      ownership: ownership(Map.get(payload, :ownership) || Map.get(payload, "ownership")),
      backlog: backlog(payload.backlog),
      control_flags: control_flags(payload.control_flags),
      tracker: tracker_overview(payload.tracker),
      questions: Enum.map(payload.questions, &question/1),
      escalations: Enum.map(payload.escalations, &escalation/1),
      provider_health: provider_health(payload.provider_health),
      events: payload.events,
      events_meta: Map.get(payload, :events_meta) || Map.get(payload, "events_meta"),
      coordination:
        coordination(Map.get(payload, :coordination) || Map.get(payload, "coordination")),
      workflows: workflow_overview(payload.workflows),
      babysitter: babysitter(payload.babysitter),
      slots: slots(Map.get(payload, :slots) || Map.get(payload, "slots"))
    }
  end

  def coordination(%Result{} = result) do
    %{
      schema_version: result.schema_version,
      status: result.status,
      selected_playbook_id: result.selected_playbook_id,
      event_source: result.event_source,
      cursor: coordination_cursor(result.cursor),
      summary: coordination_summary(result.summary),
      brief: result.brief,
      recommendations: Enum.map(result.recommendations, &coordination_recommendation/1),
      playbooks: Enum.map(result.playbooks, &coordination_playbook/1),
      timeline: Enum.map(result.timeline, &coordination_timeline_entry/1),
      warnings: result.warnings
    }
  end

  def coordination(nil), do: nil

  def runtime_state(nil), do: nil
  def runtime_state(%RuntimeState{} = state), do: RuntimeState.to_map(state)

  def runtime_owner(nil), do: nil

  def runtime_owner(owner) when is_map(owner) do
    %{
      current: Map.get(owner, :current) || Map.get(owner, "current"),
      live?: Map.get(owner, :live?) || Map.get(owner, "live?") || false,
      stale?: Map.get(owner, :stale?) || Map.get(owner, "stale?") || false,
      reclaimable?: Map.get(owner, :reclaimable?) || Map.get(owner, "reclaimable?") || false,
      legacy?: Map.get(owner, :legacy?) || Map.get(owner, "legacy?") || false,
      state: Map.get(owner, :state) || Map.get(owner, "state"),
      error: Map.get(owner, :error) || Map.get(owner, "error"),
      start_allowed?: Map.get(owner, :start_allowed?) || Map.get(owner, "start_allowed?") || false
    }
  end

  def ownership(nil), do: nil

  def ownership(payload) when is_map(payload) do
    %{
      summary_state: Map.get(payload, :summary_state) || Map.get(payload, "summary_state"),
      headline: Map.get(payload, :headline) || Map.get(payload, "headline"),
      detail: Map.get(payload, :detail) || Map.get(payload, "detail"),
      start_allowed?: Map.get(payload, :start_allowed?) || Map.get(payload, "start_allowed?") || false,
      conflict?: Map.get(payload, :conflict?) || Map.get(payload, "conflict?") || false,
      fail_closed?: Map.get(payload, :fail_closed?) || Map.get(payload, "fail_closed?") || false,
      start_gate: sanitize(Map.get(payload, :start_gate) || Map.get(payload, "start_gate")),
      runtime_owner: sanitize(Map.get(payload, :runtime_owner) || Map.get(payload, "runtime_owner")),
      active_run: sanitize(Map.get(payload, :active_run) || Map.get(payload, "active_run"))
    }
  end

  def backlog(%PlanStore.Backlog{} = backlog) do
    %{
      source: backlog_source(backlog.source),
      exists?: backlog.exists?,
      needs_build?: backlog.needs_build?,
      items: Enum.map(backlog.items, &plan_item/1)
    }
  end

  defp backlog_source(%{
         kind: kind,
         label: label,
         path: path,
         canonical?: canonical?,
         phase: phase
       }) do
    %{
      kind: Atom.to_string(kind),
      label: label,
      path: path,
      canonical?: canonical?,
      phase: phase
    }
  end

  def control_flags(%{
        pause_requested?: pause_requested?,
        replan_requested?: replan_requested?,
        deploy_requested?: deploy_requested?,
        ingest_logs_requested?: ingest_logs_requested?,
        workflow_requested?: workflow_requested?,
        workflow_target: workflow_target
      }) do
    %{
      pause_requested?: pause_requested?,
      replan_requested?: replan_requested?,
      deploy_requested?: deploy_requested?,
      ingest_logs_requested?: ingest_logs_requested?,
      workflow_requested?: workflow_requested?,
      workflow_target: workflow_target
    }
  end

  defp coordination_cursor(%Cursor{} = cursor) do
    %{
      requested_after: cursor.requested_after,
      next_after: cursor.next_after,
      cursor_found: cursor.cursor_found,
      truncated: cursor.truncated,
      reset_required: cursor.reset_required
    }
  end

  defp coordination_summary(%Summary{} = summary) do
    %{
      fetched_events: summary.fetched_events,
      unique_events: summary.unique_events,
      duplicate_events: summary.duplicate_events,
      actionable_events: summary.actionable_events,
      recommendations: summary.recommendations,
      playbooks: coordination_playbook_counts(summary.playbooks)
    }
  end

  defp coordination_playbook_counts(%PlaybookCounts{} = counts) do
    %{
      total: counts.total,
      actionable: counts.actionable,
      blocked: counts.blocked,
      observe: counts.observe
    }
  end

  defp coordination_recommendation(%Recommendation{} = recommendation) do
    %{
      rule: recommendation.rule,
      action: recommendation.action,
      playbook_id: recommendation.playbook_id,
      event_id: recommendation.event_id,
      event_code: recommendation.event_code,
      event_action: recommendation.event_action,
      event_occurred_at: recommendation.event_occurred_at,
      reason: recommendation.reason,
      apply_eligible: recommendation.apply_eligible,
      blocked_by: recommendation.blocked_by
    }
  end

  defp coordination_playbook(%Playbook{} = playbook) do
    %{
      id: playbook.id,
      title: playbook.title,
      goal: playbook.goal,
      status: playbook.status,
      reason: playbook.reason,
      evidence: sanitize(playbook.evidence),
      recommended_action: playbook.recommended_action,
      apply_eligible: playbook.apply_eligible,
      blocked_by: playbook.blocked_by,
      steps: sanitize(playbook.steps)
    }
  end

  defp coordination_timeline_entry(%TimelineEntry{} = entry) do
    %{
      event_id: entry.event_id,
      event_code: entry.event_code,
      event_action: entry.event_action,
      occurred_at: entry.occurred_at,
      surface: entry.surface,
      kind: entry.kind,
      title: entry.title,
      detail: entry.detail,
      related_playbook_ids: entry.related_playbook_ids
    }
  end

  def tracker_overview(%TrackerOverview{} = overview) do
    %{
      sources: %{
        backlog: backlog_source(overview.sources.backlog),
        workflows: backlog_source(overview.sources.workflows)
      },
      counts: overview.counts,
      issues: Enum.map(overview.issues, &tracker_issue/1)
    }
  end

  def question(%Question{} = question) do
    %{
      id: question.id,
      opened_at: question.opened_at,
      category: question.category,
      question: question.question,
      status_label: question.status_label,
      status_kind: question.status_kind,
      suggested_action: question.suggested_action,
      suggested_command: question.suggested_command,
      escalation_log: question.escalation_log,
      evidence: question.evidence,
      answer: question.answer,
      revision: question.revision
    }
  end

  def escalation(%Escalation{} = escalation) do
    %{
      id: escalation.id,
      opened_at: escalation.opened_at,
      kind: escalation.kind,
      repeat_count: escalation.repeat_count,
      requested_action: escalation.requested_action,
      summary: escalation.summary,
      evidence: escalation.evidence,
      host: escalation.host,
      draft: escalation.draft
    }
  end

  def tracker_issue(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      workflow_state: issue.workflow_state,
      url: issue.url,
      labels: issue.labels,
      assignees: issue.assignees,
      created_at: iso_datetime(issue.created_at),
      updated_at: iso_datetime(issue.updated_at)
    }
  end

  def workflow_overview(%Overview{} = overview) do
    %{
      runtime_state: runtime_state(overview.runtime_state),
      workflows: Enum.map(overview.workflows, &workflow_summary/1)
    }
  end

  def workflow_summary(%WorkflowSummary{} = summary) do
    %{
      entry: workflow_entry(summary.entry),
      preflight: action_snapshot(summary.preflight),
      run: action_snapshot(summary.run),
      history: workflow_history(summary.history),
      active_run: workflow_active_run(summary.active_run),
      latest_activity_kind: summary.latest_activity_kind,
      latest_activity_at: summary.latest_activity_at
    }
  end

  def provider_health(payload) when is_map(payload), do: sanitize(payload)

  def babysitter(%{
        managed?: managed?,
        lane: lane,
        action: action,
        mode: mode,
        workflow_name: workflow_name,
        branch: branch,
        runtime_surface: runtime_surface,
        snapshot: snapshot,
        active_run_state: active_run_state,
        active_run_error: active_run_error,
        active_run: active_run,
        running?: running?
      }) do
    %{
      managed?: managed?,
      lane: lane,
      action: action,
      mode: mode,
      workflow_name: workflow_name,
      branch: branch,
      runtime_surface: runtime_surface,
      running?: running?,
      snapshot: sanitize(snapshot),
      active_run_state: active_run_state,
      active_run_error: active_run_error,
      active_run: sanitize(active_run)
    }
  end

  def action_result(%{question: %Question{} = question} = result) do
    %{question: question(question), changed?: Map.get(result, :changed?, false)}
  end

  def action_result(result) when is_map(result), do: sanitize(result)

  def slots(nil), do: %{items: [], counts: %{total: 0, active: 0, blocked: 0, completed: 0, failed: 0, stopped: 0}, limits: %{read: 0, write: 0}}

  def slots(payload) when is_map(payload) do
    %{
      items: Enum.map(Map.get(payload, :items) || Map.get(payload, "items") || [], &sanitize/1),
      counts: sanitize(Map.get(payload, :counts) || Map.get(payload, "counts") || %{}),
      limits: sanitize(Map.get(payload, :limits) || Map.get(payload, "limits") || %{})
    }
  end

  defp workflow_entry(%WorkflowCatalogEntry{} = entry) do
    %{
      name: entry.name,
      root: entry.root,
      graph_file: entry.graph_file,
      config_file: entry.config_file,
      prompts_dir: entry.prompts_dir,
      scripts_dir: entry.scripts_dir,
      runner_kind: entry.runner_kind
    }
  end

  defp action_snapshot(%ActionSnapshot{} = snapshot) do
    %{
      kind: snapshot.kind,
      path: snapshot.path,
      status: snapshot.status,
      updated_at: snapshot.updated_at,
      size_bytes: snapshot.size_bytes,
      output: snapshot.output,
      error: serialize_error(snapshot.error)
    }
  end

  defp workflow_active_run(nil), do: nil

  defp workflow_active_run(%ActiveRun{} = active_run) do
    %{
      run_id: active_run.run_id,
      workflow_name: active_run.workflow_name,
      action: active_run.action,
      mode: active_run.mode,
      status: active_run.status,
      runtime_surface: active_run.runtime_surface,
      branch: active_run.branch,
      started_at: active_run.started_at,
      last_heartbeat_at: active_run.last_heartbeat_at
    }
  end

  defp workflow_history(%Snapshot{} = history) do
    %{
      status: history.status,
      returned_count: history.returned_count,
      retained_count: history.retained_count,
      has_more?: history.has_more?,
      counts: history_counts(history.counts),
      latest: workflow_history_entry(history.latest),
      latest_by_action: %{
        preflight: workflow_history_entry(history.latest_by_action.preflight),
        run: workflow_history_entry(history.latest_by_action.run)
      },
      entries: Enum.map(history.entries, &workflow_history_entry/1),
      error: serialize_error(history.error)
    }
  end

  defp workflow_history(nil), do: nil

  defp workflow_history_entry(nil), do: nil

  defp workflow_history_entry(%Entry{} = entry) do
    %{
      run_id: entry.run_id,
      workflow_name: entry.workflow_name,
      action: entry.action,
      outcome: entry.outcome,
      runtime_surface: entry.runtime_surface,
      branch: entry.branch,
      started_at: entry.started_at,
      finished_at: entry.finished_at,
      duration_ms: entry.duration_ms,
      summary: entry.summary,
      requested_action: entry.requested_action,
      runtime_status: entry.runtime_status,
      failure_kind: entry.failure_kind,
      error: entry.error,
      artifact: history_artifact(entry.artifact)
    }
  end

  defp history_artifact(nil), do: nil

  defp history_artifact(artifact) when is_map(artifact) do
    %{
      path: artifact.path,
      status: artifact.status,
      updated_at: artifact.updated_at,
      size_bytes: artifact.size_bytes,
      error: serialize_error(artifact.error)
    }
  end

  defp history_counts(counts) when is_map(counts) do
    %{
      total: Map.get(counts, :total, 0),
      succeeded: Map.get(counts, :succeeded, 0),
      failed: Map.get(counts, :failed, 0),
      escalated: Map.get(counts, :escalated, 0),
      stopped: Map.get(counts, :stopped, 0),
      start_failed: Map.get(counts, :start_failed, 0)
    }
  end

  defp plan_item(%Item{} = item) do
    %{
      line_number: item.line_number,
      section: item.section,
      text: item.text,
      depth: item.depth,
      status: item.status,
      raw_line: item.raw_line
    }
  end

  defp iso_datetime(nil), do: nil
  defp iso_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp serialize_error(nil), do: nil
  defp serialize_error(error) when is_binary(error), do: error
  defp serialize_error(error), do: inspect(error)

  defp sanitize(nil), do: nil
  defp sanitize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} -> {key, sanitize(nested)} end)
  end

  defp sanitize(value), do: inspect(value)
end

defmodule ForgeloopV2.Service.State do
  @moduledoc false

  defstruct [
    :config,
    :control_plane_pid,
    :owns_control_plane?,
    :listener,
    :acceptor_pid,
    :client_refs,
    :host,
    :port,
    :base_url,
    :started_at
  ]
end

defmodule ForgeloopV2.Service do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    Config,
    ControlPlane,
    Events,
    Service.State,
    ServiceContract,
    ServiceJSON,
    UIAssets
  }

  @recv_timeout_ms 5_000
  @stream_heartbeat_interval_ms 15_000
  @stream_retry_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    with {:ok, config} <- load_config(opts),
         {:ok, {host, ip}} <-
           normalize_loopback_host(Keyword.get(opts, :host, config.service_host)),
         :ok <- UIAssets.validate!(config),
         {:ok, listener} <- listen(ip, Keyword.get(opts, :port, config.service_port)),
         {:ok, port} <- listener_port(listener) do
      case start_control_plane(config, opts) do
        {:ok, control_plane_pid, owns_control_plane?} ->
          case start_accept_loop(listener, config, control_plane_pid, self()) do
            {:ok, acceptor_pid} ->
              started_at = iso_now()
              base_url = base_url_for(host, port)

              Events.emit(config, :service_http_started, %{
                "surface" => "service",
                "host" => host,
                "port" => port,
                "started_at" => started_at
              })

              {:ok,
               %State{
                 config: config,
                 control_plane_pid: control_plane_pid,
                 owns_control_plane?: owns_control_plane?,
                 listener: listener,
                 acceptor_pid: acceptor_pid,
                 client_refs: %{},
                 host: host,
                 port: port,
                 base_url: base_url,
                 started_at: started_at
               }}

            {:error, reason} ->
              maybe_stop_control_plane(control_plane_pid, owns_control_plane?)
              :gen_tcp.close(listener)
              {:stop, reason}
          end

        {:error, reason} ->
          :gen_tcp.close(listener)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    Events.emit(state.config, :service_http_stopped, %{
      "surface" => "service",
      "host" => state.host,
      "port" => state.port,
      "stopped_at" => iso_now()
    })

    if is_pid(state.acceptor_pid) and Process.alive?(state.acceptor_pid) do
      Process.exit(state.acceptor_pid, :shutdown)
    end

    Enum.each(Map.keys(state.client_refs || %{}), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    if is_port(state.listener) do
      :gen_tcp.close(state.listener)
    end

    maybe_stop_control_plane(state.control_plane_pid, state.owns_control_plane?)

    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply,
     %{
       host: state.host,
       port: state.port,
       base_url: state.base_url,
       started_at: state.started_at
     }, state}
  end

  @impl true
  def handle_info({:service_client_started, pid}, %State{} = state) when is_pid(pid) do
    ref = Process.monitor(pid)
    {:noreply, %{state | client_refs: Map.put(state.client_refs || %{}, pid, ref)}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    client_refs = state.client_refs || %{}

    if Map.get(client_refs, pid) == ref do
      {:noreply, %{state | client_refs: Map.delete(client_refs, pid)}}
    else
      {:noreply, state}
    end
  end

  defp load_config(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> {:ok, config}
      _ -> Config.load(opts)
    end
  end

  defp start_control_plane(config, opts) do
    case Keyword.get(opts, :control_plane_pid) do
      pid when is_pid(pid) ->
        {:ok, pid, false}

      _ ->
        case ControlPlane.start_link(
               config: config,
               driver: Keyword.get(opts, :driver),
               driver_opts: Keyword.get(opts, :driver_opts, []),
               name: Keyword.get(opts, :control_plane_name, ControlPlane)
             ) do
          {:ok, pid} -> {:ok, pid, true}
          {:error, {:already_started, pid}} -> {:ok, pid, false}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_loopback_host(host) when host in [nil, "", "localhost"],
    do: {:ok, {"127.0.0.1", {127, 0, 0, 1}}}

  defp normalize_loopback_host("127.0.0.1"), do: {:ok, {"127.0.0.1", {127, 0, 0, 1}}}

  defp normalize_loopback_host(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _} = ip} -> {:ok, {host, ip}}
      {:ok, ip} -> {:error, {:non_loopback_service_host, host, ip}}
      {:error, reason} -> {:error, {:invalid_service_host, host, reason}}
    end
  end

  defp normalize_loopback_host(other), do: {:error, {:invalid_service_host, other}}

  defp maybe_stop_control_plane(pid, true) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp maybe_stop_control_plane(_pid, _owns_control_plane?), do: :ok

  defp listen(ip, port) do
    :gen_tcp.listen(port, [
      :binary,
      {:active, false},
      {:packet, :raw},
      {:reuseaddr, true},
      {:backlog, 16},
      {:ip, ip}
    ])
  end

  defp listener_port(listener) do
    case :inet.sockname(listener) do
      {:ok, {_ip, port}} -> {:ok, port}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_accept_loop(listener, config, control_plane_pid, owner_pid) do
    Task.Supervisor.start_child(ForgeloopV2.TaskSupervisor, fn ->
      accept_loop(listener, config, control_plane_pid, owner_pid)
    end)
  end

  defp accept_loop(listener, config, control_plane_pid, owner_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, client_pid} =
          Task.Supervisor.start_child(ForgeloopV2.TaskSupervisor, fn ->
            handle_socket(socket, config, control_plane_pid)
          end)

        send(owner_pid, {:service_client_started, client_pid})
        accept_loop(listener, config, control_plane_pid, owner_pid)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_socket(socket, config, control_plane_pid) do
    case read_request(socket) do
      {:ok, request} ->
        case route(request, config, control_plane_pid) do
          {:stream, stream_opts} ->
            case stream_events(socket, config, control_plane_pid, stream_opts) do
              :ok ->
                :ok

              {:error, reason} ->
                send_body_response(socket, error_response(status_for_error(reason), reason))
            end

          response ->
            send_body_response(socket, response)
        end

      {:error, reason} ->
        send_body_response(socket, error_response(status_for_error(reason), reason))
    end
  after
    :gen_tcp.close(socket)
  end

  defp route(%{method: "GET", path: path}, config, _control_plane_pid)
       when path in ["/", "/index.html", "/assets/app.css", "/assets/app.js"] do
    static_asset_response(config, path)
  end

  defp route(%{method: "GET", path: "/health"}, _config, _control_plane_pid) do
    json_response(200, %{ok: true, service: "forgeloop_v2", mode: "loopback"})
  end

  defp route(%{method: "GET", path: "/api/schema"}, _config, _control_plane_pid) do
    json_response(200, %{ok: true, data: ServiceContract.descriptor()})
  end

  defp route(%{method: "GET", path: "/api/overview", query: query}, _config, control_plane_pid) do
    case ControlPlane.overview(control_plane_pid, limit: Map.get(query, "limit", 50)) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.overview(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/providers"}, _config, control_plane_pid) do
    case ControlPlane.provider_health(control_plane_pid) do
      {:ok, payload} ->
        json_response(200, %{ok: true, data: ServiceJSON.provider_health(payload)})

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp route(
         %{method: "GET", path: "/api/stream", query: query, headers: headers},
         _config,
         _control_plane_pid
       ) do
    {:stream,
     %{
       limit: Map.get(query, "limit", 50),
       after: stream_after_cursor(query, headers)
     }}
  end

  defp route(%{method: "GET", path: "/api/runtime"}, _config, control_plane_pid) do
    case ControlPlane.runtime(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.runtime_state(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/backlog"}, _config, control_plane_pid) do
    case ControlPlane.backlog(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.backlog(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/tracker"}, _config, control_plane_pid) do
    case ControlPlane.tracker(control_plane_pid) do
      {:ok, payload} ->
        json_response(200, %{ok: true, data: ServiceJSON.tracker_overview(payload)})

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/questions"}, _config, control_plane_pid) do
    case ControlPlane.questions(control_plane_pid) do
      {:ok, questions} ->
        json_response(200, %{ok: true, data: Enum.map(questions, &ServiceJSON.question/1)})

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/slots"}, _config, control_plane_pid) do
    case ControlPlane.slots(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.slots(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/escalations"}, _config, control_plane_pid) do
    case ControlPlane.escalations(control_plane_pid) do
      {:ok, escalations} ->
        json_response(200, %{ok: true, data: Enum.map(escalations, &ServiceJSON.escalation/1)})

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/events", query: query}, _config, control_plane_pid) do
    case ControlPlane.events(control_plane_pid,
           limit: Map.get(query, "limit", 50),
           after: Map.get(query, "after")
         ) do
      {:ok, result} -> json_response(200, %{ok: true, data: result.items, meta: result.meta})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(
         %{method: "GET", path: "/api/coordination", query: query},
         _config,
         control_plane_pid
       ) do
    playbook_id = Map.get(query, "playbook_id", Map.get(query, "playbookId"))

    case ControlPlane.coordination(control_plane_pid,
           limit: Map.get(query, "limit", 50),
           after: Map.get(query, "after"),
           playbook_id: playbook_id,
           playbook_provided?:
             Map.has_key?(query, "playbook_id") or Map.has_key?(query, "playbookId")
         ) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.coordination(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/workflows", query: query}, _config, control_plane_pid) do
    case ControlPlane.workflow_overview(control_plane_pid,
           include_output?: truthy?(Map.get(query, "include_output"))
         ) do
      {:ok, payload} ->
        json_response(200, %{ok: true, data: ServiceJSON.workflow_overview(payload)})

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: path, query: query}, _config, control_plane_pid) do
    case String.split(path, "/", trim: true) do
      ["api", "workflows", name] ->
        case ControlPlane.workflow_fetch(control_plane_pid, URI.decode(name),
               include_output?: truthy?(Map.get(query, "include_output"))
             ) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.workflow_summary(payload)})

          :missing ->
            error_response(404, :not_found)

          {:error, reason} ->
            error_response(status_for_error(reason), reason)
        end

      ["api", "slots", slot_id] ->
        case ControlPlane.slot_fetch(control_plane_pid, URI.decode(slot_id)) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          :missing ->
            error_response(404, :not_found)

          {:error, reason} ->
            error_response(status_for_error(reason), reason)
        end

      ["api", "babysitter"] ->
        case ControlPlane.babysitter(control_plane_pid) do
          {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.babysitter(payload)})
          {:error, reason} -> error_response(status_for_error(reason), reason)
        end

      _ ->
        error_response(404, :not_found)
    end
  end

  defp route(%{method: "POST", path: "/api/control/pause"}, _config, control_plane_pid) do
    case ControlPlane.pause(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/control/clear-pause"}, _config, control_plane_pid) do
    case ControlPlane.clear_pause(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/control/replan"}, _config, control_plane_pid) do
    case ControlPlane.replan(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/control/run", json: body}, _config, control_plane_pid) do
    case ControlPlane.start_run(
           control_plane_pid,
           Map.get(body, "mode"),
           branch: Map.get(body, "branch"),
           runtime_surface: Map.get(body, "surface", "ui")
         ) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> start_error_response(control_plane_pid, reason)
    end
  end

  defp route(%{method: "POST", path: "/api/slots", json: body}, _config, control_plane_pid) do
    case ControlPlane.start_slot(control_plane_pid,
           lane: Map.get(body, "lane"),
           action: Map.get(body, "action", Map.get(body, "mode")),
           workflow_name: Map.get(body, "workflow_name", Map.get(body, "workflowName")),
           branch: Map.get(body, "branch"),
           runtime_surface: Map.get(body, "surface", "ui"),
           ephemeral: Map.get(body, "ephemeral", true)
         ) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> start_error_response(control_plane_pid, reason)
    end
  end

  defp route(
         %{method: "POST", path: "/api/babysitter/start", json: body},
         _config,
         control_plane_pid
       ) do
    case ControlPlane.start_run(
           control_plane_pid,
           Map.get(body, "mode"),
           branch: Map.get(body, "branch"),
           runtime_surface: "babysitter"
         ) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> start_error_response(control_plane_pid, reason)
    end
  end

  defp route(
         %{method: "POST", path: "/api/babysitter/stop", json: body},
         _config,
         control_plane_pid
       ) do
    case ControlPlane.stop_run(control_plane_pid, Map.get(body, "reason", "pause")) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: path, json: body}, _config, control_plane_pid) do
    case String.split(path, "/", trim: true) do
      ["api", "workflows", workflow_name, "preflight"] ->
        case ControlPlane.start_workflow(
               control_plane_pid,
               URI.decode(workflow_name),
               "preflight",
               branch: Map.get(body, "branch"),
               runtime_surface: Map.get(body, "surface", "ui")
             ) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          {:error, reason} ->
            start_error_response(control_plane_pid, reason)
        end

      ["api", "workflows", workflow_name, "run"] ->
        case ControlPlane.start_workflow(
               control_plane_pid,
               URI.decode(workflow_name),
               "run",
               branch: Map.get(body, "branch"),
               runtime_surface: Map.get(body, "surface", "ui"),
               runner_args: Map.get(body, "runner_args", [])
             ) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          {:error, reason} ->
            start_error_response(control_plane_pid, reason)
        end

      ["api", "slots", slot_id, "stop"] ->
        case ControlPlane.stop_slot(control_plane_pid, URI.decode(slot_id), Map.get(body, "reason", "pause")) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          {:error, reason} ->
            error_response(status_for_error(reason), reason)
        end

      ["api", "questions", question_id, "answer"] ->
        case ControlPlane.answer_question(
               control_plane_pid,
               URI.decode(question_id),
               Map.get(body, "answer", ""),
               expected_revision: Map.get(body, "expected_revision")
             ) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          {:error, reason} ->
            error_response(status_for_error(reason), reason)
        end

      ["api", "questions", question_id, "resolve"] ->
        opts =
          [expected_revision: Map.get(body, "expected_revision")]
          |> maybe_put_answer(Map.get(body, "answer"))

        case ControlPlane.resolve_question(control_plane_pid, URI.decode(question_id), opts) do
          {:ok, payload} ->
            json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})

          {:error, reason} ->
            error_response(status_for_error(reason), reason)
        end

      _ ->
        error_response(404, :not_found)
    end
  end

  defp route(%{method: _method}, _config, _control_plane_pid) do
    error_response(404, :not_found)
  end

  defp read_request(socket, buffer \\ "") do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_index, 4} ->
        header_blob = binary_part(buffer, 0, header_index)
        remaining = binary_part(buffer, header_index + 4, byte_size(buffer) - header_index - 4)

        with {:ok, request_line, headers} <- parse_head(header_blob),
             {:ok, body} <- read_body(socket, remaining, content_length(headers)),
             {:ok, request} <- build_request(request_line, headers, body) do
          {:ok, request}
        end

      :nomatch ->
        case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
          {:ok, chunk} -> read_request(socket, buffer <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_head(header_blob) do
    case String.split(header_blob, "\r\n", trim: true) do
      [request_line | header_lines] -> {:ok, request_line, parse_headers(header_lines)}
      _ -> {:error, :invalid_http_request}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp read_body(_socket, body, 0), do: {:ok, body}

  defp read_body(_socket, body, expected_length) when byte_size(body) >= expected_length do
    {:ok, binary_part(body, 0, expected_length)}
  end

  defp read_body(socket, body, expected_length) do
    case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
      {:ok, chunk} -> read_body(socket, body <> chunk, expected_length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_request(request_line, headers, body) do
    case String.split(request_line, " ", parts: 3) do
      [method, raw_path, _version] ->
        uri = URI.parse(raw_path)

        with {:ok, json} <- decode_json_body(body, headers) do
          {:ok,
           %{
             method: method,
             path: uri.path || "/",
             query: URI.decode_query(uri.query || ""),
             headers: headers,
             body: body,
             json: json
           }}
        end

      _ ->
        {:error, :invalid_http_request}
    end
  end

  defp decode_json_body("", _headers), do: {:ok, %{}}

  defp decode_json_body(body, headers) do
    content_type = Map.get(headers, "content-type", "application/json")

    if String.starts_with?(content_type, "application/json") do
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) -> {:ok, payload}
        {:ok, _payload} -> {:error, :invalid_json_body}
        {:error, _reason} -> {:error, :invalid_json_body}
      end
    else
      {:error, :unsupported_content_type}
    end
  end

  defp content_length(headers) do
    headers
    |> Map.get("content-length", "0")
    |> Integer.parse()
    |> case do
      {length, ""} when length >= 0 -> length
      _ -> 0
    end
  end

  defp json_response(status, payload) do
    body_response(status, "application/json", Jason.encode!(ServiceContract.wrap_envelope(payload)))
  end

  defp start_error_response(control_plane_pid, reason) do
    opts =
      case start_error_ownership(control_plane_pid, reason) do
        ownership when is_map(ownership) -> [ownership: ownership]
        _ -> []
      end

    error_response(status_for_error(reason), reason, opts)
  end

  defp start_error_ownership(control_plane_pid, reason) do
    if ownership_error_reason?(reason) do
      case ControlPlane.ownership(control_plane_pid) do
        {:ok, ownership} ->
          ownership
          |> normalize_start_error_ownership(reason)
          |> ServiceJSON.ownership()

        _ ->
          nil
      end
    else
      nil
    end
  catch
    :exit, _reason -> nil
  end

  defp normalize_start_error_ownership(ownership, {:active_run_state_error, reason})
       when is_map(ownership) do
    start_gate = Map.get(ownership, :start_gate, %{})

    if Map.get(start_gate, :reason) == "active_run_state_error" do
      ownership
    else
      active_run =
        ownership
        |> Map.get(:active_run, %{})
        |> Map.put(:state, "error")
        |> Map.put(:error, format_active_run_state_error(reason))

      ownership
      |> Map.put(:summary_state, "error")
      |> Map.put(:headline, "Managed run metadata is malformed")
      |> Map.put(:detail, "Starts fail closed until #{format_active_run_state_error(reason)} is repaired or removed.")
      |> Map.put(:start_allowed?, false)
      |> Map.put(:conflict?, false)
      |> Map.put(:fail_closed?, true)
      |> Map.put(:gate_error, {:active_run_state_error, reason})
      |> Map.put(:active_run, active_run)
      |> Map.put(:start_gate, %{
        status: "error",
        reason: "active_run_state_error",
        http_status: 500,
        reclaim_on_start?: false,
        cleanup_on_start?: false,
        details: active_run
      })
    end
  end

  defp normalize_start_error_ownership(ownership, _reason), do: ownership

  defp ownership_error_reason?(:babysitter_already_running), do: true
  defp ownership_error_reason?({:babysitter_unmanaged_active, _payload}), do: true
  defp ownership_error_reason?({:active_runtime_owned_by, current}) when is_map(current), do: true
  defp ownership_error_reason?({:active_runtime_state_error, runtime_owner}) when is_map(runtime_owner), do: true
  defp ownership_error_reason?({:active_run_state_error, _reason}), do: true
  defp ownership_error_reason?({:slot_capacity_reached, _class, _limit}), do: false
  defp ownership_error_reason?({:slot_action_deferred, _lane, _action}), do: false
  defp ownership_error_reason?(_reason), do: false

  defp format_active_run_state_error(reason) when is_binary(reason), do: reason
  defp format_active_run_state_error(reason), do: inspect(reason)

  defp error_response(status, reason, opts \\ []) do
    json_response(status, %{ok: false, error: error_payload(reason, opts)})
  end

  defp error_payload({:question_conflict, question_id, current_revision}, opts) do
    %{
      reason: "question_conflict",
      question_id: question_id,
      current_revision: current_revision,
      detail: inspect({:question_conflict, question_id, current_revision})
    }
    |> maybe_put_error_ownership(opts)
  end

  defp error_payload({:active_runtime_owned_by, current}, opts) when is_map(current) do
    %{
      reason: "active_runtime_owned_by",
      detail: inspect({:active_runtime_owned_by, current}),
      details: current
    }
    |> maybe_put_error_ownership(opts)
  end

  defp error_payload({:active_runtime_state_error, runtime_owner}, opts) when is_map(runtime_owner) do
    %{
      reason: "active_runtime_state_error",
      detail: inspect({:active_runtime_state_error, runtime_owner}),
      details: runtime_owner
    }
    |> maybe_put_error_ownership(opts)
  end

  defp error_payload({:active_run_state_error, reason}, opts) do
    %{
      reason: "active_run_state_error",
      detail: inspect({:active_run_state_error, reason}),
      details: if(is_binary(reason), do: reason, else: inspect(reason))
    }
    |> maybe_put_error_ownership(opts)
  end

  defp error_payload(reason, opts) do
    %{
      reason: error_code(reason),
      detail: inspect(reason)
    }
    |> maybe_put_error_ownership(opts)
  end

  defp maybe_put_error_ownership(payload, opts) do
    case Keyword.get(opts, :ownership) do
      ownership when is_map(ownership) -> Map.put(payload, :ownership, ownership)
      _ -> payload
    end
  end

  defp error_code({:missing_expected_revision, _}), do: "missing_expected_revision"
  defp error_code({:blank_answer, _}), do: "blank_answer"
  defp error_code({:question_not_found, _}), do: "question_not_found"
  defp error_code({:invalid_mode, _}), do: "invalid_mode"
  defp error_code({:invalid_workflow_action, _}), do: "invalid_workflow_action"
  defp error_code({:invalid_workflow_name, _}), do: "invalid_workflow_name"
  defp error_code({:invalid_runner_args, _}), do: "invalid_runner_args"
  defp error_code({:invalid_coordination_playbook, _}), do: "invalid_coordination_playbook"
  defp error_code({:workflow_not_found, _}), do: "workflow_not_found"
  defp error_code({:invalid_runtime_surface, _}), do: "invalid_runtime_surface"
  defp error_code({:invalid_stop_reason, _}), do: "invalid_stop_reason"
  defp error_code({:workflow_name_required, _}), do: "workflow_name_required"
  defp error_code({:unsupported_slot_action, _, _}), do: "unsupported_slot_action"
  defp error_code({:slot_action_deferred, _, _}), do: "slot_action_deferred"
  defp error_code({:slot_capacity_reached, class, _limit}), do: "#{class}_slot_capacity_reached"
  defp error_code({:slot_not_found, _}), do: "slot_not_found"
  defp error_code(:slot_not_running), do: "slot_not_running"
  defp error_code(:invalid_slot_lane), do: "invalid_slot_lane"
  defp error_code(:invalid_slot_action), do: "invalid_slot_action"
  defp error_code(:invalid_slot_request), do: "invalid_slot_request"
  defp error_code({:babysitter_unmanaged_active, _}), do: "babysitter_unmanaged_active"
  defp error_code({:active_runtime_owned_by, _}), do: "active_runtime_owned_by"
  defp error_code({:active_runtime_state_error, _}), do: "active_runtime_state_error"
  defp error_code({:active_run_state_error, _}), do: "active_run_state_error"
  defp error_code(:babysitter_already_running), do: "babysitter_already_running"
  defp error_code(:babysitter_not_running), do: "babysitter_not_running"
  defp error_code(:babysitter_not_managed), do: "babysitter_not_managed"
  defp error_code(:invalid_json_body), do: "invalid_json_body"
  defp error_code(:unsupported_content_type), do: "unsupported_content_type"
  defp error_code(:invalid_http_request), do: "invalid_http_request"
  defp error_code(:not_found), do: "not_found"
  defp error_code(reason), do: inspect(reason)

  defp status_for_error({:missing_expected_revision, _}), do: 400
  defp status_for_error({:blank_answer, _}), do: 400
  defp status_for_error({:invalid_mode, _}), do: 400
  defp status_for_error({:invalid_workflow_action, _}), do: 400
  defp status_for_error({:invalid_workflow_name, _}), do: 400
  defp status_for_error({:invalid_runner_args, _}), do: 400
  defp status_for_error({:invalid_coordination_playbook, _}), do: 400
  defp status_for_error({:invalid_runtime_surface, _}), do: 400
  defp status_for_error({:invalid_stop_reason, _}), do: 400
  defp status_for_error({:workflow_name_required, _}), do: 400
  defp status_for_error({:unsupported_slot_action, _, _}), do: 400
  defp status_for_error({:slot_action_deferred, _, _}), do: 409
  defp status_for_error({:slot_capacity_reached, _, _}), do: 409
  defp status_for_error(:invalid_slot_lane), do: 400
  defp status_for_error(:invalid_slot_action), do: 400
  defp status_for_error(:invalid_slot_request), do: 400
  defp status_for_error(:invalid_json_body), do: 400
  defp status_for_error(:unsupported_content_type), do: 415
  defp status_for_error(:invalid_http_request), do: 400
  defp status_for_error({:question_not_found, _}), do: 404
  defp status_for_error({:workflow_not_found, _}), do: 404
  defp status_for_error({:slot_not_found, _}), do: 404
  defp status_for_error(:not_found), do: 404
  defp status_for_error({:question_conflict, _, _}), do: 409
  defp status_for_error({:babysitter_unmanaged_active, _}), do: 409
  defp status_for_error({:active_runtime_owned_by, _}), do: 409
  defp status_for_error({:active_runtime_state_error, _}), do: 500
  defp status_for_error({:active_run_state_error, _}), do: 500
  defp status_for_error(:babysitter_already_running), do: 409
  defp status_for_error(:babysitter_not_running), do: 409
  defp status_for_error(:babysitter_not_managed), do: 409
  defp status_for_error(:slot_not_running), do: 409
  defp status_for_error(_), do: 500

  defp body_response(status, content_type, body) do
    {:body, status, [{"content-type", content_type}], body}
  end

  defp static_asset_response(config, path) do
    case UIAssets.fetch(config, path) do
      {:ok, %{content_type: content_type, body: body}} ->
        body_response(200, content_type, body)

      :missing ->
        error_response(404, :not_found)

      {:error, reason} ->
        error_response(status_for_error(reason), reason)
    end
  end

  defp send_body_response(socket, {:body, status, headers, body}) do
    response =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason_phrase(status),
        "\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    :gen_tcp.send(socket, response)
  end

  defp stream_events(socket, config, control_plane_pid, stream_opts) do
    limit = stream_limit(Map.get(stream_opts, :limit, 50))
    after_cursor = normalize_stream_after(Map.get(stream_opts, :after))
    event_log_path = Events.event_log_path(config)

    case send_sse_headers(socket) do
      :ok ->
        with :ok <- Events.subscribe(config),
             {:ok, handoff} <-
               send_initial_stream_payload(socket, control_plane_pid, limit, after_cursor),
             :ok <- flush_buffered_events(socket, event_log_path, handoff.delivered_ids) do
          try do
            stream_loop(socket, event_log_path, 0)
          after
            Events.unsubscribe(config)
          end
        else
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp send_initial_stream_payload(socket, control_plane_pid, limit, nil) do
    case overview_payload(control_plane_pid, limit) do
      {:ok, payload} ->
        json = Jason.encode!(ServiceContract.wrap_envelope(%{ok: true, data: payload}))

        with :ok <- send_snapshot(socket, json) do
          {:ok, %{delivered_ids: delivered_event_ids(payload.events || [])}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_initial_stream_payload(socket, control_plane_pid, limit, after_cursor) do
    case events_result(control_plane_pid, after_cursor, limit) do
      {:ok, %{items: items, meta: %{cursor_found?: true, truncated?: false}}} ->
        with :ok <- send_replay_events(socket, items) do
          {:ok, %{delivered_ids: delivered_event_ids(items)}}
        end

      {:ok, %{meta: %{cursor_found?: false}}} ->
        send_initial_stream_payload(socket, control_plane_pid, limit, nil)

      {:ok, %{meta: %{truncated?: true}}} ->
        send_initial_stream_payload(socket, control_plane_pid, limit, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_loop(socket, event_log_path, idle_ms) do
    receive do
      {:forgeloop_v2_event, path, event} ->
        if path == event_log_path do
          case send_event(socket, event) do
            :ok -> stream_loop(socket, event_log_path, 0)
            {:error, _reason} -> :ok
          end
        else
          stream_loop(socket, event_log_path, idle_ms)
        end
    after
      @stream_heartbeat_interval_ms ->
        case :gen_tcp.send(socket, ": keepalive\n\n") do
          :ok -> stream_loop(socket, event_log_path, idle_ms + @stream_heartbeat_interval_ms)
          {:error, _reason} -> :ok
        end
    end
  end

  defp overview_payload(control_plane_pid, limit) do
    case ControlPlane.overview(control_plane_pid, limit: limit) do
      {:ok, payload} -> {:ok, ServiceJSON.overview(payload)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :control_plane_unavailable}
  end

  defp events_result(control_plane_pid, after_cursor, limit) do
    case ControlPlane.events(control_plane_pid, after: after_cursor, limit: limit) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :control_plane_unavailable}
  end

  defp send_sse_headers(socket) do
    :gen_tcp.send(
      socket,
      [
        "HTTP/1.1 200 ",
        reason_phrase(200),
        "\r\n",
        "content-type: text/event-stream\r\n",
        "cache-control: no-cache\r\n",
        "connection: close\r\n",
        "\r\n",
        "retry: ",
        Integer.to_string(@stream_retry_ms),
        "\n\n"
      ]
    )
  end

  defp send_snapshot(socket, json) do
    :gen_tcp.send(socket, ["event: snapshot\n", "data: ", json, "\n\n"])
  end

  defp send_replay_events(socket, items) do
    Enum.reduce_while(items, :ok, fn event, _acc ->
      case send_event(socket, event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp flush_buffered_events(socket, event_log_path, delivered_ids) do
    receive do
      {:forgeloop_v2_event, path, event} when path == event_log_path ->
        event_id = event["event_id"]

        if MapSet.member?(delivered_ids, event_id) do
          flush_buffered_events(socket, event_log_path, delivered_ids)
        else
          case send_event(socket, event) do
            :ok ->
              flush_buffered_events(socket, event_log_path, MapSet.put(delivered_ids, event_id))

            {:error, reason} ->
              {:error, reason}
          end
        end
    after
      0 -> :ok
    end
  end

  defp delivered_event_ids(events) do
    events
    |> Enum.reduce(MapSet.new(), fn event, acc ->
      case event["event_id"] do
        id when is_binary(id) -> MapSet.put(acc, id)
        _ -> acc
      end
    end)
  end

  defp send_event(socket, event) do
    json = Jason.encode!(ServiceContract.wrap_envelope(%{ok: true, data: event}))

    :gen_tcp.send(socket, [
      "id: ",
      to_string(event["event_id"] || ""),
      "\n",
      "event: event\n",
      "data: ",
      json,
      "\n\n"
    ])
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(409), do: "Conflict"
  defp reason_phrase(415), do: "Unsupported Media Type"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_), do: "OK"

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_), do: false

  defp stream_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)

  defp stream_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} when int > 0 -> min(int, 500)
      _ -> 50
    end
  end

  defp stream_limit(_), do: 50

  defp stream_after_cursor(query, headers) do
    normalize_stream_after(Map.get(query, "after") || Map.get(headers, "last-event-id"))
  end

  defp normalize_stream_after(nil), do: nil

  defp normalize_stream_after(cursor) when is_binary(cursor) do
    case String.trim(cursor) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_stream_after(_), do: nil

  defp maybe_put_answer(opts, nil), do: opts
  defp maybe_put_answer(opts, answer), do: Keyword.put(opts, :answer, answer)

  defp base_url_for(host, port), do: "http://#{host}:#{port}"

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
