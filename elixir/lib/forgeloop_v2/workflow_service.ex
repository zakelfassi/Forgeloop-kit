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

defmodule ForgeloopV2.WorkflowService.WorkflowSummary do
  @moduledoc false

  alias ForgeloopV2.WorkflowCatalog.Entry
  alias ForgeloopV2.WorkflowService.ActionSnapshot

  defstruct [
    :entry,
    :preflight,
    :run,
    :latest_activity_kind,
    :latest_activity_at
  ]

  @type t :: %__MODULE__{
          entry: Entry.t(),
          preflight: ActionSnapshot.t(),
          run: ActionSnapshot.t(),
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

  alias ForgeloopV2.{Config, PathPolicy, RuntimeState, RuntimeStateStore, WorkflowCatalog}
  alias ForgeloopV2.WorkflowCatalog.Entry
  alias ForgeloopV2.WorkflowService.{ActionSnapshot, Overview, WorkflowSummary}

  @workflow_runtime_surface "workflow"
  @workflow_runtime_modes ["workflow-preflight", "workflow-run"]

  @spec list(Config.t(), keyword()) :: {:ok, [WorkflowSummary.t()]}
  def list(%Config{} = config, opts \\ []) do
    {:ok, Enum.map(WorkflowCatalog.list(config), &workflow_summary(config, &1, opts))}
  end

  @spec fetch(Config.t(), String.t(), keyword()) :: {:ok, WorkflowSummary.t()} | :missing | {:error, term()}
  def fetch(%Config{} = config, name, opts \\ []) when is_binary(name) do
    case WorkflowCatalog.fetch(config, name) do
      {:ok, entry} -> {:ok, workflow_summary(config, entry, opts)}
      :missing -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec overview(Config.t(), keyword()) :: {:ok, Overview.t()}
  def overview(%Config{} = config, opts \\ []) do
    {:ok,
     %Overview{
       runtime_state: workflow_runtime_state(config),
       workflows: WorkflowCatalog.list(config) |> Enum.map(&workflow_summary(config, &1, opts))
     }}
  end

  defp workflow_summary(%Config{} = config, %Entry{} = entry, opts) do
    preflight = action_snapshot(config, entry, :preflight, opts)
    run = action_snapshot(config, entry, :run, opts)
    {latest_activity_kind, latest_activity_at} = latest_activity(preflight, run)

    %WorkflowSummary{
      entry: entry,
      preflight: preflight,
      run: run,
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

  defp latest_activity(%ActionSnapshot{} = preflight, %ActionSnapshot{} = run) do
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

  defp workflow_runtime_state(%Config{} = config) do
    case RuntimeStateStore.read(config) do
      {:ok, %RuntimeState{surface: @workflow_runtime_surface, mode: mode} = state}
      when mode in @workflow_runtime_modes -> state

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
