defmodule ForgeloopV2.Slots.Slot do
  @moduledoc false

  defstruct [
    :slot_id,
    :lane,
    :action,
    :mode,
    :workflow_name,
    :branch,
    :ephemeral,
    :write_class,
    :coordination_scope,
    :status,
    :runtime_surface,
    :worktree_path,
    :started_at,
    :updated_at,
    :run_id,
    :last_result,
    :blocked_reason
  ]

  @type t :: %__MODULE__{}
end

defmodule ForgeloopV2.Slots do
  @moduledoc false

  alias ForgeloopV2.{
    Config,
    Coordination,
    Events,
    RuntimeStateStore
  }

  alias ForgeloopV2.Slots.Slot

  @slot_schema_version 1

  @spec root(Config.t()) :: Path.t()
  def root(%Config{} = config), do: Path.join(config.v2_state_dir, "slots")

  @spec slot_dir(Config.t(), String.t()) :: Path.t()
  def slot_dir(%Config{} = config, slot_id), do: Path.join(root(config), slot_id)

  @spec slot_metadata_path(Config.t(), String.t()) :: Path.t()
  def slot_metadata_path(%Config{} = config, slot_id), do: Path.join(slot_dir(config, slot_id), "slot.json")

  @spec slot_runtime_state_path(Config.t(), String.t()) :: Path.t()
  def slot_runtime_state_path(%Config{} = config, slot_id),
    do: Path.join(slot_dir(config, slot_id), "runtime-state.json")

  @spec slot_coordination_dir(Config.t(), String.t()) :: Path.t()
  def slot_coordination_dir(%Config{} = config, slot_id),
    do: Path.join(slot_dir(config, slot_id), "coordination")

  @spec slot_plan_path(Config.t(), String.t()) :: Path.t()
  def slot_plan_path(%Config{} = config, slot_id),
    do: Path.join(slot_coordination_dir(config, slot_id), "IMPLEMENTATION_PLAN.md")

  @spec slot_requests_path(Config.t(), String.t()) :: Path.t()
  def slot_requests_path(%Config{} = config, slot_id),
    do: Path.join(slot_coordination_dir(config, slot_id), "REQUESTS.md")

  @spec slot_questions_path(Config.t(), String.t()) :: Path.t()
  def slot_questions_path(%Config{} = config, slot_id),
    do: Path.join(slot_coordination_dir(config, slot_id), "QUESTIONS.md")

  @spec slot_escalations_path(Config.t(), String.t()) :: Path.t()
  def slot_escalations_path(%Config{} = config, slot_id),
    do: Path.join(slot_coordination_dir(config, slot_id), "ESCALATIONS.md")

  @spec slot_config(Config.t(), String.t(), :slot_local | :canonical) :: Config.t()
  def slot_config(%Config{} = base_config, slot_id, coordination_scope \\ :slot_local)
      when is_binary(slot_id) and slot_id != "" do
    slot_root = slot_dir(base_config, slot_id)

    coordination_files =
      case coordination_scope do
        :canonical ->
          %{
            requests_file: base_config.requests_file,
            questions_file: base_config.questions_file,
            escalations_file: base_config.escalations_file,
            plan_file: base_config.plan_file
          }

        :slot_local ->
          %{
            requests_file: slot_requests_path(base_config, slot_id),
            questions_file: slot_questions_path(base_config, slot_id),
            escalations_file: slot_escalations_path(base_config, slot_id),
            plan_file: slot_plan_path(base_config, slot_id)
          }
      end

    %Config{
      base_config
      | runtime_dir: slot_root,
        runtime_state_file: slot_runtime_state_path(base_config, slot_id),
        v2_state_dir: Path.join(slot_root, "v2"),
        requests_file: coordination_files.requests_file,
        questions_file: coordination_files.questions_file,
        escalations_file: coordination_files.escalations_file,
        plan_file: coordination_files.plan_file
    }
  end

  @spec initialize_slot_files(Config.t(), String.t()) :: :ok | {:error, term()}
  def initialize_slot_files(%Config{} = config, slot_id) when is_binary(slot_id) and slot_id != "" do
    slot_root = slot_dir(config, slot_id)
    coordination_dir = slot_coordination_dir(config, slot_id)
    slot_runtime_dir = Path.join(slot_root, "v2")

    with :ok <- File.mkdir_p(slot_root),
         :ok <- File.mkdir_p(coordination_dir),
         :ok <- File.mkdir_p(slot_runtime_dir),
         :ok <- File.mkdir_p(Path.join(slot_runtime_dir, "driver")),
         :ok <- File.mkdir_p(Path.join(slot_runtime_dir, "workflows")),
         :ok <- maybe_copy(config.plan_file, slot_plan_path(config, slot_id)),
         :ok <- write_if_missing(slot_requests_path(config, slot_id), ""),
         :ok <- write_if_missing(slot_questions_path(config, slot_id), ""),
         :ok <- write_if_missing(slot_escalations_path(config, slot_id), "") do
      :ok
    end
  end

  @spec list(Config.t()) :: [Slot.t()]
  def list(%Config{} = config) do
    config
    |> root()
    |> Path.join("*/slot.json")
    |> Path.wildcard()
    |> Enum.map(&read_slot_file/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, slot} -> hydrate(config, slot) end)
    |> Enum.sort_by(&{&1.updated_at || "", &1.slot_id}, :desc)
  end

  @spec fetch(Config.t(), String.t()) :: {:ok, Slot.t()} | :missing | {:error, term()}
  def fetch(%Config{} = config, slot_id) when is_binary(slot_id) and slot_id != "" do
    case read_slot_file(slot_metadata_path(config, slot_id)) do
      {:ok, slot} -> {:ok, hydrate(config, slot)}
      :missing -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write(Config.t(), Slot.t()) :: :ok | {:error, term()}
  def write(%Config{} = config, %Slot{} = slot) do
    path = slot_metadata_path(config, slot.slot_id)
    File.mkdir_p!(Path.dirname(path))
    body = Jason.encode!(slot_payload(slot), pretty: true) <> "\n"
    File.write(path, body)
  end

  @spec delete(Config.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Config{} = config, slot_id) do
    path = slot_metadata_path(config, slot_id)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_stale_runs(Config.t()) :: :ok
  def mark_stale_runs(%Config{} = config) do
    Enum.each(list(config), fn slot ->
      if slot.status in ["starting", "running"] do
        slot
        |> Map.put(:status, "stale")
        |> Map.put(:blocked_reason, "slot_coordinator_restarted")
        |> Map.put(:last_result, "slot coordinator restarted while slot metadata still reported an active run")
        |> Map.put(:updated_at, iso_now())
        |> then(&write(config, &1))

        cleanup_slot_stale_runtime(config, slot.slot_id)
      end
    end)
  end

  @spec summary(Slot.t()) :: map()
  def summary(%Slot{} = slot) do
    %{
      slot_id: slot.slot_id,
      lane: slot.lane,
      action: slot.action,
      mode: slot.mode,
      workflow_name: slot.workflow_name,
      branch: slot.branch,
      ephemeral: slot.ephemeral,
      write_class: slot.write_class,
      coordination_scope: effective_coordination_scope(slot),
      status: slot.status,
      runtime_surface: slot.runtime_surface,
      worktree_path: slot.worktree_path,
      started_at: slot.started_at,
      updated_at: slot.updated_at,
      run_id: slot.run_id,
      last_result: slot.last_result,
      blocked_reason: slot.blocked_reason
    }
  end

  @spec detail(Config.t(), Slot.t()) :: map()
  def detail(%Config{} = config, %Slot{} = slot) do
    slot_config = slot_config(config, slot.slot_id, effective_coordination_scope_atom(slot))
    runtime_state = read_runtime_state(slot_config)
    questions = read_questions(slot_config)
    escalations = read_escalations(slot_config)
    events = read_events(slot_config)

    summary(slot)
    |> Map.put(:runtime_state, runtime_state)
    |> Map.put(:questions, questions)
    |> Map.put(:escalations, escalations)
    |> Map.put(:events, events)
    |> Map.put(:coordination_paths, %{
      requests: slot_config.requests_file,
      questions: slot_config.questions_file,
      escalations: slot_config.escalations_file,
      plan: slot_config.plan_file
    })
  end

  defp slot_payload(%Slot{} = slot) do
    %{
      "schema_version" => @slot_schema_version,
      "slot_id" => slot.slot_id,
      "lane" => slot.lane,
      "action" => slot.action,
      "mode" => slot.mode,
      "workflow_name" => slot.workflow_name,
      "branch" => slot.branch,
      "ephemeral" => slot.ephemeral,
      "write_class" => slot.write_class,
      "coordination_scope" => effective_coordination_scope(slot),
      "status" => slot.status,
      "runtime_surface" => slot.runtime_surface,
      "worktree_path" => slot.worktree_path,
      "started_at" => slot.started_at,
      "updated_at" => slot.updated_at,
      "run_id" => slot.run_id,
      "last_result" => slot.last_result,
      "blocked_reason" => slot.blocked_reason
    }
  end

  defp read_slot_file(path) do
    case File.read(path) do
      {:ok, body} ->
        with {:ok, payload} when is_map(payload) <- Jason.decode(body) do
          {:ok,
           %Slot{
             slot_id: string_value(payload, "slot_id"),
             lane: string_value(payload, "lane"),
             action: string_value(payload, "action"),
             mode: string_value(payload, "mode"),
             workflow_name: blank_to_nil(string_value(payload, "workflow_name")),
             branch: string_value(payload, "branch"),
             ephemeral: truthy?(payload, "ephemeral"),
             write_class: string_value(payload, "write_class"),
             coordination_scope: blank_to_nil(string_value(payload, "coordination_scope")),
             status: string_value(payload, "status"),
             runtime_surface: string_value(payload, "runtime_surface"),
             worktree_path: blank_to_nil(string_value(payload, "worktree_path")),
             started_at: blank_to_nil(string_value(payload, "started_at")),
             updated_at: blank_to_nil(string_value(payload, "updated_at")),
             run_id: blank_to_nil(string_value(payload, "run_id")),
             last_result: normalize_optional(payload["last_result"]),
             blocked_reason: blank_to_nil(string_value(payload, "blocked_reason"))
           }}
        else
          {:ok, _payload} -> {:error, {:invalid_slot_payload, path}}
          {:error, reason} -> {:error, {:invalid_slot_json, path, reason}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hydrate(%Config{} = config, %Slot{} = slot) do
    slot_config = slot_config(config, slot.slot_id, effective_coordination_scope_atom(slot))
    runtime_state = read_runtime_state(slot_config)
    events = read_events(slot_config)
    latest_event = List.last(events)

    slot
    |> Map.put(:status, derive_status(slot, runtime_state))
    |> Map.put(:last_result, slot.last_result || derive_last_result(runtime_state, latest_event))
    |> Map.put(:blocked_reason, slot.blocked_reason || derive_blocked_reason(runtime_state))
    |> Map.put(:updated_at, slot.updated_at || runtime_state["updated_at"] || event_time(latest_event))
  end

  defp derive_status(%Slot{status: status}, nil), do: status || "unknown"

  defp derive_status(%Slot{} = slot, runtime_state) do
    case runtime_state["status"] do
      "running" -> "running"
      "blocked" -> "blocked"
      "awaiting-human" -> "blocked"
      "paused" -> if(slot.status == "stopped", do: "stopped", else: "blocked")
      "idle" -> if(slot.status in ["stopped", "failed"], do: slot.status, else: "completed")
      _ -> slot.status || "unknown"
    end
  end

  defp derive_last_result(nil, latest_event), do: event_code(latest_event)

  defp derive_last_result(runtime_state, latest_event) do
    runtime_state["reason"] || event_code(latest_event)
  end

  defp derive_blocked_reason(nil), do: nil
  defp derive_blocked_reason(runtime_state), do: blank_to_nil(runtime_state["reason"])

  defp read_runtime_state(%Config{} = config) do
    case RuntimeStateStore.read(config) do
      {:ok, state} -> ForgeloopV2.RuntimeState.to_map(state)
      :missing -> nil
      {:error, _reason} -> nil
    end
  end

  defp read_questions(%Config{} = config) do
    case Coordination.read_questions(config) do
      {:ok, questions} -> Enum.map(questions, &%{id: &1.id, status_kind: &1.status_kind, question: &1.question})
      _ -> []
    end
  end

  defp read_escalations(%Config{} = config) do
    case Coordination.read_escalations(config) do
      {:ok, escalations} -> Enum.map(escalations, &%{id: &1.id, summary: &1.summary, requested_action: &1.requested_action})
      _ -> []
    end
  end

  defp read_events(%Config{} = config) do
    case Events.tail(config, limit: 10) do
      {:ok, %{items: items}} -> items
      _ -> []
    end
  end

  defp cleanup_slot_stale_runtime(%Config{} = config, slot_id) do
    slot_config = slot_config(config, slot_id)
    _ = ForgeloopV2.Worktree.cleanup_stale(slot_config)
    :ok
  end

  defp effective_coordination_scope(%Slot{coordination_scope: scope}) when scope in ["canonical", "slot_local"],
    do: scope

  defp effective_coordination_scope(%Slot{write_class: "write"}), do: "canonical"
  defp effective_coordination_scope(%Slot{}), do: "slot_local"

  defp effective_coordination_scope_atom(slot) do
    case effective_coordination_scope(slot) do
      "canonical" -> :canonical
      _ -> :slot_local
    end
  end

  defp maybe_copy(source, target) do
    case File.read(source) do
      {:ok, body} -> File.write(target, body)
      {:error, :enoent} -> write_if_missing(target, "")
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_if_missing(path, body) do
    case File.read(path) do
      {:ok, _} -> :ok
      {:error, :enoent} -> File.write(path, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp truthy?(payload, key) do
    case Map.get(payload, key) do
      true -> true
      "true" -> true
      1 -> true
      _ -> false
    end
  end

  defp string_value(payload, key) do
    value = Map.get(payload, key) || Map.get(payload, String.to_atom(key), "")

    cond do
      is_binary(value) -> value
      is_nil(value) -> ""
      true -> to_string(value)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_optional(nil), do: nil
  defp normalize_optional(value) when is_binary(value), do: value
  defp normalize_optional(value) when is_map(value) or is_list(value), do: value
  defp normalize_optional(value), do: to_string(value)

  defp event_code(nil), do: nil
  defp event_code(event), do: event["event_code"] || event["event_type"]

  defp event_time(nil), do: nil
  defp event_time(event), do: event["occurred_at"] || event["recorded_at"]

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
