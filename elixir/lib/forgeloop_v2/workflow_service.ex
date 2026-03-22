defmodule ForgeloopV2.WorkflowService.ActionSnapshot do
  @moduledoc false

  defstruct [
    :kind,
    :path,
    :status,
    :updated_at,
    :size_bytes,
    :output,
    :error
  ]

  @type t :: %__MODULE__{
          kind: :preflight | :run,
          path: Path.t(),
          status: :missing | :available | :error,
          updated_at: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          output: String.t() | nil,
          error: term() | nil
        }
end

defmodule ForgeloopV2.WorkflowService.ActiveRun do
  @moduledoc false

  defstruct [
    :run_id,
    :workflow_name,
    :action,
    :mode,
    :status,
    :runtime_surface,
    :branch,
    :started_at,
    :last_heartbeat_at
  ]

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          workflow_name: String.t(),
          action: :preflight | :run,
          mode: String.t(),
          status: String.t() | nil,
          runtime_surface: String.t() | nil,
          branch: String.t() | nil,
          started_at: String.t() | nil,
          last_heartbeat_at: String.t() | nil
        }
end

defmodule ForgeloopV2.WorkflowService.WorkflowSummary do
  @moduledoc false

  alias ForgeloopV2.WorkflowCatalog.Entry
  alias ForgeloopV2.WorkflowHistory
  alias ForgeloopV2.WorkflowService.{ActionSnapshot, ActiveRun}

  defstruct [
    :entry,
    :preflight,
    :run,
    :history,
    :active_run,
    :latest_activity_kind,
    :latest_activity_at
  ]

  @type t :: %__MODULE__{
          entry: Entry.t(),
          preflight: ActionSnapshot.t(),
          run: ActionSnapshot.t(),
          history: WorkflowHistory.Snapshot.t(),
          active_run: ActiveRun.t() | nil,
          latest_activity_kind: :preflight | :run | nil,
          latest_activity_at: String.t() | nil
        }
end

defmodule ForgeloopV2.WorkflowService.Overview do
  @moduledoc false

  alias ForgeloopV2.RuntimeState
  alias ForgeloopV2.WorkflowService.WorkflowSummary

  defstruct [:runtime_state, :workflows]

  @type t :: %__MODULE__{
          runtime_state: RuntimeState.t() | nil,
          workflows: [WorkflowSummary.t()]
        }
end

defmodule ForgeloopV2.WorkflowService do
  @moduledoc false

  alias ForgeloopV2.{Config, PathPolicy, RuntimeState, RuntimeStateStore, WorkflowCatalog, WorkflowHistory, Worktree}
  alias ForgeloopV2.WorkflowCatalog.Entry
  alias ForgeloopV2.WorkflowService.{ActionSnapshot, ActiveRun, Overview, WorkflowSummary}

  @workflow_runtime_modes ["workflow-preflight", "workflow-run"]

  @spec list(Config.t(), keyword()) :: {:ok, [WorkflowSummary.t()]}
  def list(%Config{} = config, opts \\ []) do
    active_run = current_workflow_active_run(config)
    {:ok, Enum.map(WorkflowCatalog.list(config), &workflow_summary(config, &1, active_run, opts))}
  end

  @spec fetch(Config.t(), String.t(), keyword()) :: {:ok, WorkflowSummary.t()} | :missing | {:error, term()}
  def fetch(%Config{} = config, name, opts \\ []) when is_binary(name) do
    active_run = current_workflow_active_run(config)

    case WorkflowCatalog.fetch(config, name) do
      {:ok, entry} -> {:ok, workflow_summary(config, entry, active_run, opts)}
      :missing -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec overview(Config.t(), keyword()) :: {:ok, Overview.t()}
  def overview(%Config{} = config, opts \\ []) do
    active_run = current_workflow_active_run(config)

    {:ok,
     %Overview{
       runtime_state: workflow_runtime_state(config),
       workflows: WorkflowCatalog.list(config) |> Enum.map(&workflow_summary(config, &1, active_run, opts))
     }}
  end

  defp workflow_summary(%Config{} = config, %Entry{} = entry, active_run, opts) do
    preflight = action_snapshot(config, entry, :preflight, opts)
    run = action_snapshot(config, entry, :run, opts)
    history =
      case WorkflowHistory.fetch(config, entry.name, limit: Keyword.get(opts, :history_limit, 5)) do
        {:ok, snapshot} -> snapshot
        {:error, reason} -> %WorkflowHistory.Snapshot{status: :error, entries: [], returned_count: 0, retained_count: 0, has_more?: false, counts: %{total: 0, succeeded: 0, failed: 0, escalated: 0, stopped: 0, start_failed: 0}, latest: nil, latest_by_action: %{preflight: nil, run: nil}, error: reason}
      end

    {latest_activity_kind, latest_activity_at} = latest_activity(preflight, run, history)

    %WorkflowSummary{
      entry: entry,
      preflight: preflight,
      run: run,
      history: history,
      active_run: matching_active_run(active_run, entry.name),
      latest_activity_kind: latest_activity_kind,
      latest_activity_at: latest_activity_at
    }
  end

  defp action_snapshot(%Config{} = config, %Entry{name: workflow_name}, kind, opts) do
    path = workflow_artifact_path(config, workflow_name, kind)
    include_output? = Keyword.get(opts, :include_output?, false)

    case PathPolicy.validate_owned_path(config, path, :runtime) do
      {:ok, validated_path} -> read_snapshot(validated_path, kind, include_output?)
      {:error, reason} -> error_snapshot(kind, path, reason)
    end
  end

  defp workflow_artifact_path(%Config{} = config, workflow_name, kind) do
    Path.join([config.runtime_dir, "workflows", workflow_name, artifact_file_name(kind)])
  end

  defp artifact_file_name(:preflight), do: "last-preflight.txt"
  defp artifact_file_name(:run), do: "last-run.txt"

  defp read_snapshot(path, kind, include_output?) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
        base_snapshot = %ActionSnapshot{
          kind: kind,
          path: path,
          status: :available,
          updated_at: iso_from_unix(mtime),
          size_bytes: size,
          output: nil,
          error: nil
        }

        maybe_read_output(base_snapshot, include_output?)

      {:ok, %File.Stat{type: :symlink}} ->
        error_snapshot(kind, path, {:symlink_artifact_path, path})

      {:ok, %File.Stat{type: type}} ->
        error_snapshot(kind, path, {:unsupported_artifact_type, type})

      {:error, :enoent} ->
        %ActionSnapshot{kind: kind, path: path, status: :missing, output: nil, error: nil}

      {:error, reason} ->
        error_snapshot(kind, path, reason)
    end
  end

  defp maybe_read_output(%ActionSnapshot{} = snapshot, false), do: snapshot

  defp maybe_read_output(%ActionSnapshot{path: path} = snapshot, true) do
    case File.read(path) do
      {:ok, output} -> %{snapshot | output: output}
      {:error, :enoent} -> %{snapshot | status: :missing, output: nil, error: nil}
      {:error, reason} -> %{snapshot | status: :error, output: nil, error: reason}
    end
  end

  defp latest_activity(%ActionSnapshot{} = preflight, %ActionSnapshot{} = run, history) do
    case history && history.latest do
      %{action: action} = latest when action in [:preflight, :run] ->
        {action, latest.finished_at || latest.started_at}

      _ ->
        latest_activity_from_artifacts(preflight, run)
    end
  end

  defp latest_activity_from_artifacts(%ActionSnapshot{} = preflight, %ActionSnapshot{} = run) do
    preflight_at = preflight.updated_at
    run_at = run.updated_at

    cond do
      is_nil(preflight_at) and is_nil(run_at) -> {nil, nil}
      is_nil(preflight_at) -> {:run, run_at}
      is_nil(run_at) -> {:preflight, preflight_at}
      run_at >= preflight_at -> {:run, run_at}
      true -> {:preflight, preflight_at}
    end
  end

  defp current_workflow_active_run(%Config{} = config) do
    case Worktree.read_active_run(config) do
      {:ok, payload} -> active_run_from_payload(payload)
      _ -> nil
    end
  end

  defp active_run_from_payload(payload) when is_map(payload) do
    mode = Map.get(payload, "mode")
    workflow_name = Map.get(payload, "workflow_name")
    lane = Map.get(payload, "lane")

    with true <- is_binary(workflow_name),
         true <- is_binary(mode) and mode in @workflow_runtime_modes,
         true <- lane in [nil, "workflow"],
         {:ok, action} <- action_from_payload(Map.get(payload, "action"), mode) do
      %ActiveRun{
        run_id: Map.get(payload, "run_id"),
        workflow_name: workflow_name,
        action: action,
        mode: mode,
        status: Map.get(payload, "status"),
        runtime_surface: Map.get(payload, "runtime_surface"),
        branch: Map.get(payload, "branch"),
        started_at: Map.get(payload, "started_at"),
        last_heartbeat_at: Map.get(payload, "last_heartbeat_at")
      }
    else
      _ -> nil
    end
  end

  defp active_run_from_payload(_payload), do: nil

  defp action_from_payload("preflight", _mode), do: {:ok, :preflight}
  defp action_from_payload("run", _mode), do: {:ok, :run}
  defp action_from_payload(nil, "workflow-preflight"), do: {:ok, :preflight}
  defp action_from_payload(nil, "workflow-run"), do: {:ok, :run}
  defp action_from_payload(_action, _mode), do: :error

  defp matching_active_run(%ActiveRun{workflow_name: workflow_name} = active_run, workflow_name), do: active_run
  defp matching_active_run(_active_run, _workflow_name), do: nil

  defp workflow_runtime_state(%Config{} = config) do
    case RuntimeStateStore.read(config) do
      {:ok, %RuntimeState{mode: mode} = state} when mode in @workflow_runtime_modes -> state
      _ -> nil
    end
  end

  defp error_snapshot(kind, path, reason) do
    %ActionSnapshot{kind: kind, path: path, status: :error, output: nil, error: reason}
  end

  defp iso_from_unix(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
