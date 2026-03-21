defmodule ForgeloopV2.ControlPlane.State do
  @moduledoc false

  defstruct [
    :config,
    :driver,
    :driver_opts,
    :started_at,
    :babysitter_pid,
    :babysitter_ref,
    :babysitter_mode,
    :babysitter_branch,
    :last_action,
    :last_result
  ]
end

defmodule ForgeloopV2.ControlPlane do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{
    Babysitter,
    Config,
    ControlFiles,
    Coordination,
    Events,
    PlanStore,
    RuntimeLifecycle,
    RuntimeStateStore,
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
  def overview(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:overview, opts}, :infinity)

  @spec runtime(GenServer.server()) :: {:ok, ForgeloopV2.RuntimeState.t() | nil} | {:error, term()}
  def runtime(server \\ __MODULE__), do: GenServer.call(server, :runtime)

  @spec backlog(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def backlog(server \\ __MODULE__), do: GenServer.call(server, :backlog)

  @spec questions(GenServer.server()) :: {:ok, [ForgeloopV2.Coordination.Question.t()]} | {:error, term()}
  def questions(server \\ __MODULE__), do: GenServer.call(server, :questions)

  @spec escalations(GenServer.server()) :: {:ok, [ForgeloopV2.Coordination.Escalation.t()]} | {:error, term()}
  def escalations(server \\ __MODULE__), do: GenServer.call(server, :escalations)

  @spec events(GenServer.server(), keyword()) :: {:ok, [map()]}
  def events(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:events, opts})

  @spec workflow_overview(GenServer.server(), keyword()) :: {:ok, ForgeloopV2.WorkflowService.Overview.t()} | {:error, term()}
  def workflow_overview(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:workflow_overview, opts})

  @spec workflow_fetch(GenServer.server(), String.t(), keyword()) ::
          {:ok, ForgeloopV2.WorkflowService.WorkflowSummary.t()} | :missing | {:error, term()}
  def workflow_fetch(server \\ __MODULE__, name, opts \\ []), do: GenServer.call(server, {:workflow_fetch, name, opts})

  @spec babysitter(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def babysitter(server \\ __MODULE__), do: GenServer.call(server, :babysitter)

  @spec pause(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause, :infinity)

  @spec replan(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def replan(server \\ __MODULE__), do: GenServer.call(server, :replan, :infinity)

  @spec answer_question(GenServer.server(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def answer_question(server \\ __MODULE__, question_id, answer, opts \\ []) do
    GenServer.call(server, {:answer_question, question_id, answer, opts}, :infinity)
  end

  @spec resolve_question(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_question(server \\ __MODULE__, question_id, opts \\ []) do
    GenServer.call(server, {:resolve_question, question_id, opts}, :infinity)
  end

  @spec start_run(GenServer.server(), :plan | :build | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_run(server \\ __MODULE__, mode, opts \\ []) do
    GenServer.call(server, {:start_run, mode, opts}, :infinity)
  end

  @spec stop_run(GenServer.server(), :pause | :kill | String.t()) :: {:ok, map()} | {:error, term()}
  def stop_run(server \\ __MODULE__, reason \\ :pause) do
    GenServer.call(server, {:stop_run, reason}, :infinity)
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        state = %State{
          config: config,
          driver: Keyword.get(opts, :driver) || default_driver(config),
          driver_opts: Keyword.get(opts, :driver_opts, []),
          started_at: iso_now(),
          last_action: nil,
          last_result: nil
        }

        Events.emit(config, :control_plane_started, %{
          "surface" => "service",
          "started_at" => state.started_at
        })

        {:ok, state}

      _ ->
        case Config.load(opts) do
          {:ok, config} -> init(Keyword.put(opts, :config, config))
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %State{config: config, babysitter_pid: pid}) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
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
       babysitter_mode: state.babysitter_mode,
       babysitter_branch: state.babysitter_branch
     }, state}
  end

  def handle_call({:overview, opts}, _from, %State{} = state) do
    reply =
      with {:ok, runtime_state} <- read_runtime_state(state.config),
           {:ok, backlog} <- read_backlog(state.config),
           {:ok, questions} <- read_questions(state.config),
           {:ok, escalations} <- read_escalations(state.config),
           {:ok, workflow_overview} <- WorkflowService.overview(state.config),
           {:ok, babysitter} <- babysitter_status(state, Keyword.get(opts, :include_active_run?, true)) do
        {:ok,
         %{
           runtime_state: runtime_state,
           backlog: backlog,
           questions: questions,
           escalations: escalations,
           events: limited_events(state.config, opts),
           workflows: workflow_overview,
           babysitter: babysitter
         }}
      end

    {:reply, reply, state}
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

  def handle_call(:escalations, _from, %State{} = state) do
    {:reply, read_escalations(state.config), state}
  end

  def handle_call({:events, opts}, _from, %State{} = state) do
    {:reply, {:ok, limited_events(state.config, opts)}, state}
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
        {:reply, {:error, reason}, %{state | last_action: :replan_failed, last_result: {:error, reason}}}
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
        {:reply, {:error, reason}, %{state | last_action: :answer_question_failed, last_result: {:error, reason}}}
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
        {:reply, {:error, reason}, %{state | last_action: :resolve_question_failed, last_result: {:error, reason}}}
    end
  end

  def handle_call({:start_run, mode, opts}, _from, %State{} = state) do
    case do_start_run(state, mode, opts) do
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

  @impl true
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
         :ok <- maybe_stop_managed_babysitter(state, running_snapshot) do
      Events.emit(state.config, :operator_action, %{
        "surface" => "service",
        "action" => "pause_requested",
        "recorded_at" => iso_now()
      })

      {:ok, %{requested?: true, babysitter: running_snapshot}, %{state | last_action: :pause, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :pause_failed, last_result: {:error, reason}}}
    end
  end

  defp do_start_run(%State{} = state, mode, opts) do
    with {:ok, normalized_mode} <- normalize_mode(mode),
         {:ok, babysitter} <- babysitter_status(state, true),
         :ok <- ensure_start_allowed(babysitter),
         {:ok, next_state, pid} <- ensure_babysitter_instance(state, normalized_mode, opts),
         :ok <- Babysitter.start_run(pid),
         {:ok, updated_babysitter} <- babysitter_status(next_state, true) do
      Events.emit(state.config, :operator_action, %{
        "surface" => "service",
        "action" => "start_run",
        "mode" => Atom.to_string(normalized_mode),
        "recorded_at" => iso_now()
      })

      {:ok,
       %{
         mode: Atom.to_string(normalized_mode),
         surface: "babysitter",
         babysitter: updated_babysitter
       }, %{next_state | last_action: {:start_run, normalized_mode}, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :start_run_failed, last_result: {:error, reason}}}
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

      {:ok, %{stopped?: true, babysitter: updated_babysitter}, %{state | last_action: {:stop_run, normalized_reason}, last_result: :ok}}
    else
      {:error, reason} ->
        {:error, reason, %{state | last_action: :stop_run_failed, last_result: {:error, reason}}}
      false ->
        {:error, :babysitter_not_running, %{state | last_action: :stop_run_failed, last_result: {:error, :babysitter_not_running}}}
    end
  end

  defp read_runtime_state(config) do
    case RuntimeStateStore.read(config) do
      {:ok, state} -> {:ok, state}
      :missing -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_backlog(config) do
    case PlanStore.read(config) do
      {:ok, items} -> {:ok, %{needs_build?: PlanStore.needs_build?(config), items: Enum.filter(items, &(&1.status == :pending))}}
      :missing -> {:ok, %{needs_build?: true, items: []}}
      {:error, reason} -> {:error, reason}
    end
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

  defp limited_events(config, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> normalize_limit()
    config |> Events.read_all() |> Enum.take(-limit)
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} when int > 0 -> min(int, 500)
      _ -> 50
    end
  end
  defp normalize_limit(_), do: 50

  defp babysitter_status(%State{} = state, include_active_run?) do
    managed_snapshot =
      case state.babysitter_pid do
        pid when is_pid(pid) -> if(Process.alive?(pid), do: Babysitter.snapshot(pid), else: nil)
        _ -> nil
      end

    active_run =
      if include_active_run? do
        case Worktree.read_active_run(state.config) do
          {:ok, payload} -> payload
          :missing -> nil
          {:error, reason} -> %{error: inspect(reason)}
        end
      else
        nil
      end

    {:ok,
     %{
       managed?: not is_nil(managed_snapshot),
       mode: state.babysitter_mode,
       branch: state.babysitter_branch,
       snapshot: managed_snapshot,
       active_run: active_run,
       running?: babysitter_running?(managed_snapshot, active_run)
     }}
  end

  defp babysitter_running?(%{running?: true}, _active_run), do: true
  defp babysitter_running?(_managed_snapshot, %{"status" => status}) when status in ["running", "stopping"], do: true
  defp babysitter_running?(_, _), do: false

  defp maybe_pause_runtime(_config, %{running?: true, managed?: false}), do: :ok
  defp maybe_pause_runtime(_config, %{active_run: %{"status" => status}}) when status in ["running", "stopping"], do: :ok

  defp maybe_pause_runtime(config, _babysitter) do
    case RuntimeStateStore.status(config) do
      status when status in ["running", "paused", "awaiting-human"] -> :ok
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

  defp ensure_start_allowed(%{running?: true, managed?: true}), do: {:error, :babysitter_already_running}
  defp ensure_start_allowed(%{running?: true, active_run: active_run}), do: {:error, {:babysitter_unmanaged_active, active_run}}
  defp ensure_start_allowed(_), do: :ok

  defp ensure_babysitter_instance(%State{} = state, mode, opts) do
    branch = opts[:branch] || state.config.default_branch

    cond do
      reusable_babysitter?(state, mode, branch) ->
        {:ok, state, state.babysitter_pid}

      is_pid(state.babysitter_pid) ->
        if Process.alive?(state.babysitter_pid) do
          Process.exit(state.babysitter_pid, :shutdown)
        end

        start_babysitter(state, mode, branch)

      true ->
        start_babysitter(state, mode, branch)
    end
  end

  defp start_babysitter(%State{} = state, mode, branch) do
    case Babysitter.start_link(
           config: state.config,
           mode: mode,
           branch: branch,
           driver: state.driver,
           driver_opts: state.driver_opts,
           name: nil
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, %{state | babysitter_pid: pid, babysitter_ref: ref, babysitter_mode: mode, babysitter_branch: branch}, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reusable_babysitter?(%State{babysitter_pid: pid, babysitter_mode: mode, babysitter_branch: branch}, mode, branch)
       when is_pid(pid) do
    Process.alive?(pid)
  end

  defp reusable_babysitter?(_, _, _), do: false

  defp managed_babysitter_pid(%State{babysitter_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :babysitter_not_managed}
  end

  defp managed_babysitter_pid(_state), do: {:error, :babysitter_not_managed}

  defp clear_babysitter(%State{} = state) do
    %{state | babysitter_pid: nil, babysitter_ref: nil, babysitter_mode: nil, babysitter_branch: nil}
  end

  defp normalize_mode(:plan), do: {:ok, :plan}
  defp normalize_mode(:build), do: {:ok, :build}
  defp normalize_mode("plan"), do: {:ok, :plan}
  defp normalize_mode("build"), do: {:ok, :build}
  defp normalize_mode(other), do: {:error, {:invalid_mode, other}}

  defp normalize_stop_reason(:pause), do: {:ok, :pause}
  defp normalize_stop_reason(:kill), do: {:ok, :kill}
  defp normalize_stop_reason("pause"), do: {:ok, :pause}
  defp normalize_stop_reason("kill"), do: {:ok, :kill}
  defp normalize_stop_reason(other), do: {:error, {:invalid_stop_reason, other}}

  defp default_driver(config) do
    if config.shell_driver_enabled do
      ForgeloopV2.WorkDrivers.ShellLoop
    else
      ForgeloopV2.WorkDrivers.Noop
    end
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
  alias ForgeloopV2.PlanStore.Item
  alias ForgeloopV2.RuntimeState
  alias ForgeloopV2.WorkflowCatalog.Entry
  alias ForgeloopV2.WorkflowService.{ActionSnapshot, Overview, WorkflowSummary}

  @spec overview(map()) :: map()
  def overview(payload) do
    %{
      runtime_state: runtime_state(payload.runtime_state),
      backlog: backlog(payload.backlog),
      questions: Enum.map(payload.questions, &question/1),
      escalations: Enum.map(payload.escalations, &escalation/1),
      events: payload.events,
      workflows: workflow_overview(payload.workflows),
      babysitter: babysitter(payload.babysitter)
    }
  end

  def runtime_state(nil), do: nil
  def runtime_state(%RuntimeState{} = state), do: RuntimeState.to_map(state)

  def backlog(%{needs_build?: needs_build?, items: items}) do
    %{needs_build?: needs_build?, items: Enum.map(items, &plan_item/1)}
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
      latest_activity_kind: summary.latest_activity_kind,
      latest_activity_at: summary.latest_activity_at
    }
  end

  def babysitter(%{managed?: managed?, mode: mode, branch: branch, snapshot: snapshot, active_run: active_run, running?: running?}) do
    %{
      managed?: managed?,
      mode: mode,
      branch: branch,
      running?: running?,
      snapshot: sanitize(snapshot),
      active_run: sanitize(active_run)
    }
  end

  def action_result(%{question: %Question{} = question} = result) do
    %{question: question(question), changed?: Map.get(result, :changed?, false)}
  end

  def action_result(result) when is_map(result), do: sanitize(result)

  defp workflow_entry(%Entry{} = entry) do
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
    :host,
    :port,
    :base_url,
    :started_at
  ]
end

defmodule ForgeloopV2.Service do
  @moduledoc false
  use GenServer

  alias ForgeloopV2.{Config, ControlPlane, Events, Service.State, ServiceJSON}

  @recv_timeout_ms 5_000

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
         {:ok, {host, ip}} <- normalize_loopback_host(Keyword.get(opts, :host, config.service_host)),
         {:ok, control_plane_pid, owns_control_plane?} <- start_control_plane(config, opts),
         {:ok, listener} <- listen(ip, Keyword.get(opts, :port, config.service_port)),
         {:ok, port} <- listener_port(listener),
         {:ok, acceptor_pid} <- start_accept_loop(listener, control_plane_pid) do
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
         host: host,
         port: port,
         base_url: base_url,
         started_at: started_at
       }}
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

    if is_port(state.listener) do
      :gen_tcp.close(state.listener)
    end

    if state.owns_control_plane? and is_pid(state.control_plane_pid) and Process.alive?(state.control_plane_pid) do
      Process.exit(state.control_plane_pid, :shutdown)
    end

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

  defp load_config(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> {:ok, config}
      _ -> Config.load(opts)
    end
  end

  defp start_control_plane(config, opts) do
    case Keyword.get(opts, :control_plane_pid) do
      pid when is_pid(pid) -> {:ok, pid, false}
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

  defp normalize_loopback_host(host) when host in [nil, "", "localhost"], do: {:ok, {"127.0.0.1", {127, 0, 0, 1}}}
  defp normalize_loopback_host("127.0.0.1"), do: {:ok, {"127.0.0.1", {127, 0, 0, 1}}}

  defp normalize_loopback_host(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _} = ip} -> {:ok, {host, ip}}
      {:ok, ip} -> {:error, {:non_loopback_service_host, host, ip}}
      {:error, reason} -> {:error, {:invalid_service_host, host, reason}}
    end
  end

  defp normalize_loopback_host(other), do: {:error, {:invalid_service_host, other}}

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

  defp start_accept_loop(listener, control_plane_pid) do
    Task.Supervisor.start_child(ForgeloopV2.TaskSupervisor, fn -> accept_loop(listener, control_plane_pid) end)
  end

  defp accept_loop(listener, control_plane_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _pid} =
          Task.Supervisor.start_child(ForgeloopV2.TaskSupervisor, fn ->
            handle_socket(socket, control_plane_pid)
          end)

        accept_loop(listener, control_plane_pid)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_socket(socket, control_plane_pid) do
    response =
      case read_request(socket) do
        {:ok, request} -> route(request, control_plane_pid)
        {:error, reason} -> error_response(status_for_error(reason), reason)
      end

    :ok = :gen_tcp.send(socket, encode_response(response))
    :gen_tcp.close(socket)
  end

  defp route(%{method: "GET", path: "/health"}, _control_plane_pid) do
    json_response(200, %{ok: true, service: "forgeloop_v2", mode: "loopback"})
  end

  defp route(%{method: "GET", path: "/api/overview", query: query}, control_plane_pid) do
    case ControlPlane.overview(control_plane_pid, limit: Map.get(query, "limit", 50)) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.overview(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/runtime"}, control_plane_pid) do
    case ControlPlane.runtime(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.runtime_state(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/backlog"}, control_plane_pid) do
    case ControlPlane.backlog(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.backlog(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/questions"}, control_plane_pid) do
    case ControlPlane.questions(control_plane_pid) do
      {:ok, questions} -> json_response(200, %{ok: true, data: Enum.map(questions, &ServiceJSON.question/1)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/escalations"}, control_plane_pid) do
    case ControlPlane.escalations(control_plane_pid) do
      {:ok, escalations} -> json_response(200, %{ok: true, data: Enum.map(escalations, &ServiceJSON.escalation/1)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/events", query: query}, control_plane_pid) do
    case ControlPlane.events(control_plane_pid, limit: Map.get(query, "limit", 50)) do
      {:ok, events} -> json_response(200, %{ok: true, data: events})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: "/api/workflows", query: query}, control_plane_pid) do
    case ControlPlane.workflow_overview(control_plane_pid, include_output?: truthy?(Map.get(query, "include_output"))) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.workflow_overview(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "GET", path: path, query: query}, control_plane_pid) do
    case String.split(path, "/", trim: true) do
      ["api", "workflows", name] ->
        case ControlPlane.workflow_fetch(control_plane_pid, URI.decode(name), include_output?: truthy?(Map.get(query, "include_output"))) do
          {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.workflow_summary(payload)})
          :missing -> error_response(404, :not_found)
          {:error, reason} -> error_response(status_for_error(reason), reason)
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

  defp route(%{method: "POST", path: "/api/control/pause"}, control_plane_pid) do
    case ControlPlane.pause(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/control/replan"}, control_plane_pid) do
    case ControlPlane.replan(control_plane_pid) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/babysitter/start", json: body}, control_plane_pid) do
    case ControlPlane.start_run(control_plane_pid, Map.get(body, "mode"), branch: Map.get(body, "branch")) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: "/api/babysitter/stop", json: body}, control_plane_pid) do
    case ControlPlane.stop_run(control_plane_pid, Map.get(body, "reason", "pause")) do
      {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
      {:error, reason} -> error_response(status_for_error(reason), reason)
    end
  end

  defp route(%{method: "POST", path: path, json: body}, control_plane_pid) do
    case String.split(path, "/", trim: true) do
      ["api", "questions", question_id, "answer"] ->
        case ControlPlane.answer_question(
               control_plane_pid,
               URI.decode(question_id),
               Map.get(body, "answer", ""),
               expected_revision: Map.get(body, "expected_revision")
             ) do
          {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
          {:error, reason} -> error_response(status_for_error(reason), reason)
        end

      ["api", "questions", question_id, "resolve"] ->
        opts =
          [expected_revision: Map.get(body, "expected_revision")]
          |> maybe_put_answer(Map.get(body, "answer"))

        case ControlPlane.resolve_question(control_plane_pid, URI.decode(question_id), opts) do
          {:ok, payload} -> json_response(200, %{ok: true, data: ServiceJSON.action_result(payload)})
          {:error, reason} -> error_response(status_for_error(reason), reason)
        end

      _ ->
        error_response(404, :not_found)
    end
  end

  defp route(%{method: _method}, _control_plane_pid) do
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
    {:json, status, payload}
  end

  defp error_response(status, reason) do
    {:json, status, %{ok: false, error: error_payload(reason)}}
  end

  defp error_payload({:question_conflict, question_id, current_revision}) do
    %{
      reason: "question_conflict",
      question_id: question_id,
      current_revision: current_revision,
      detail: inspect({:question_conflict, question_id, current_revision})
    }
  end

  defp error_payload(reason) do
    %{
      reason: error_code(reason),
      detail: inspect(reason)
    }
  end

  defp error_code({:missing_expected_revision, _}), do: "missing_expected_revision"
  defp error_code({:blank_answer, _}), do: "blank_answer"
  defp error_code({:question_not_found, _}), do: "question_not_found"
  defp error_code({:invalid_mode, _}), do: "invalid_mode"
  defp error_code({:invalid_stop_reason, _}), do: "invalid_stop_reason"
  defp error_code({:babysitter_unmanaged_active, _}), do: "babysitter_unmanaged_active"
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
  defp status_for_error({:invalid_stop_reason, _}), do: 400
  defp status_for_error(:invalid_json_body), do: 400
  defp status_for_error(:unsupported_content_type), do: 415
  defp status_for_error(:invalid_http_request), do: 400
  defp status_for_error({:question_not_found, _}), do: 404
  defp status_for_error(:not_found), do: 404
  defp status_for_error({:question_conflict, _, _}), do: 409
  defp status_for_error({:babysitter_unmanaged_active, _}), do: 409
  defp status_for_error(:babysitter_already_running), do: 409
  defp status_for_error(:babysitter_not_running), do: 409
  defp status_for_error(:babysitter_not_managed), do: 409
  defp status_for_error(_), do: 500

  defp encode_response({:json, status, payload}) do
    body = Jason.encode!(payload)

    [
      "HTTP/1.1 ", Integer.to_string(status), " ", reason_phrase(status), "\r\n",
      "content-type: application/json\r\n",
      "content-length: ", Integer.to_string(byte_size(body)), "\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]
    |> IO.iodata_to_binary()
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

  defp maybe_put_answer(opts, nil), do: opts
  defp maybe_put_answer(opts, answer), do: Keyword.put(opts, :answer, answer)

  defp base_url_for(host, port), do: "http://#{host}:#{port}"

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
