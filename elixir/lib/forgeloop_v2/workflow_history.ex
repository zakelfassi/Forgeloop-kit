defmodule ForgeloopV2.WorkflowHistory.Entry do
  @moduledoc false

  @type action :: :preflight | :run
  @type outcome :: :succeeded | :failed | :escalated | :stopped | :start_failed

  defstruct [
    :run_id,
    :workflow_name,
    :action,
    :outcome,
    :runtime_surface,
    :branch,
    :started_at,
    :finished_at,
    :duration_ms,
    :summary,
    :requested_action,
    :runtime_status,
    :failure_kind,
    :error,
    :artifact
  ]

  @type artifact :: %{
          path: Path.t(),
          status: :missing | :available | :error,
          updated_at: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          error: term() | nil
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          workflow_name: String.t(),
          action: action(),
          outcome: outcome(),
          runtime_surface: String.t() | nil,
          branch: String.t() | nil,
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          summary: String.t() | nil,
          requested_action: String.t() | nil,
          runtime_status: String.t() | nil,
          failure_kind: String.t() | nil,
          error: String.t() | nil,
          artifact: artifact() | nil
        }
end

defmodule ForgeloopV2.WorkflowHistory.Snapshot do
  @moduledoc false

  alias ForgeloopV2.WorkflowHistory.Entry

  defstruct [
    :status,
    :entries,
    :returned_count,
    :retained_count,
    :has_more?,
    :counts,
    :latest,
    :latest_by_action,
    :error
  ]

  @type counts :: %{
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          escalated: non_neg_integer(),
          stopped: non_neg_integer(),
          start_failed: non_neg_integer()
        }

  @type t :: %__MODULE__{
          status: :missing | :available | :error,
          entries: [Entry.t()],
          returned_count: non_neg_integer(),
          retained_count: non_neg_integer(),
          has_more?: boolean(),
          counts: counts(),
          latest: Entry.t() | nil,
          latest_by_action: %{preflight: Entry.t() | nil, run: Entry.t() | nil},
          error: term() | nil
        }
end

defmodule ForgeloopV2.WorkflowHistory do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock, PathPolicy, RunSpec, RuntimeStateStore}
  alias ForgeloopV2.WorkflowHistory.{Entry, Snapshot}

  @retained_entries 20
  @default_fetch_limit 5
  @outcomes [:succeeded, :failed, :escalated, :stopped, :start_failed]

  @spec generate_run_id(RunSpec.t()) :: String.t()
  def generate_run_id(%RunSpec{lane: :workflow, action: action, workflow_name: workflow_name}) do
    suffix = System.unique_integer([:positive])
    timestamp = System.system_time(:millisecond)
    "wf-#{sanitize_segment(workflow_name)}-#{action}-#{timestamp}-#{suffix}"
  end

  @spec history_path(Config.t(), String.t()) :: Path.t()
  def history_path(%Config{} = config, workflow_name) when is_binary(workflow_name) do
    Path.join([config.runtime_dir, "workflows", workflow_name, "history.json"])
  end

  @spec fetch(Config.t(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def fetch(%Config{} = config, workflow_name, opts \\ []) when is_binary(workflow_name) do
    with :ok <- validate_workflow_name(workflow_name),
         {:ok, validated_path} <- PathPolicy.validate_owned_path(config, history_path(config, workflow_name), :runtime) do
      {:ok, read_snapshot(validated_path, normalize_limit(opts[:limit]))}
    end
  end

  @spec record_terminal_outcome(Config.t(), RunSpec.t(), keyword()) :: :ok | {:error, term()}
  def record_terminal_outcome(%Config{} = config, %RunSpec{lane: :workflow, workflow_name: workflow_name} = run_spec, attrs)
      when is_list(attrs) do
    with :ok <- validate_workflow_name(workflow_name),
         {:ok, path} <- PathPolicy.validate_owned_path(config, history_path(config, workflow_name), :runtime),
         %Entry{} = entry <- build_entry(config, run_spec, attrs),
         {:ok, result} <-
           ControlLock.with_lock(config, path, :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
             append_entry(config, path, entry)
           end) do
      result
    end
  end

  def record_terminal_outcome(_config, _run_spec, _attrs), do: :ok

  defp append_entry(%Config{} = config, path, %Entry{} = entry) do
    with {:ok, entries} <- read_entries_for_write(path),
         false <- Enum.any?(entries, &(&1.run_id == entry.run_id)),
         :ok <- persist_entries(config, path, [entry | entries] |> Enum.take(@retained_entries)) do
      :ok
    else
      true -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_entries(%Config{} = config, path, entries) do
    body =
      %{
        "version" => 1,
        "entries" => Enum.map(entries, &entry_payload/1)
      }
      |> Jason.encode!(pretty: true)
      |> Kernel.<>("\n")

    ControlLock.atomic_write(config, path, :runtime, body)
  end

  defp read_entries_for_write(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} -> decode_entries(File.read(path))
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_history_path, path}}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_history_type, type}}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_snapshot(path, limit) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} ->
        case decode_entries(File.read(path)) do
          {:ok, entries} -> build_snapshot(entries, limit)
          {:error, reason} -> error_snapshot(reason)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        error_snapshot({:symlink_history_path, path})

      {:ok, %File.Stat{type: type}} ->
        error_snapshot({:unsupported_history_type, type})

      {:error, :enoent} ->
        missing_snapshot()

      {:error, reason} ->
        error_snapshot(reason)
    end
  end

  defp decode_entries({:ok, body}) do
    with {:ok, payload} <- Jason.decode(body),
         {:ok, entries} <- entries_from_payload(payload) do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_history_payload}
    end
  end

  defp decode_entries({:error, reason}), do: {:error, reason}

  defp entries_from_payload(%{"version" => 1, "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry_payload, {:ok, acc} ->
      case entry_from_payload(entry_payload) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp entries_from_payload(_payload), do: {:error, :invalid_history_payload}

  defp entry_from_payload(%{} = payload) do
    with {:ok, action} <- decode_enum(Map.get(payload, "action"), [:preflight, :run]),
         {:ok, outcome} <- decode_enum(Map.get(payload, "outcome"), @outcomes),
         true <- is_binary(Map.get(payload, "run_id")) || {:error, :invalid_history_run_id},
         true <- is_binary(Map.get(payload, "workflow_name")) || {:error, :invalid_history_workflow_name},
         {:ok, artifact} <- artifact_from_payload(Map.get(payload, "artifact")) do
      {:ok,
       %Entry{
         run_id: Map.get(payload, "run_id"),
         workflow_name: Map.get(payload, "workflow_name"),
         action: action,
         outcome: outcome,
         runtime_surface: Map.get(payload, "runtime_surface"),
         branch: Map.get(payload, "branch"),
         started_at: Map.get(payload, "started_at"),
         finished_at: Map.get(payload, "finished_at"),
         duration_ms: Map.get(payload, "duration_ms"),
         summary: Map.get(payload, "summary"),
         requested_action: Map.get(payload, "requested_action"),
         runtime_status: Map.get(payload, "runtime_status"),
         failure_kind: Map.get(payload, "failure_kind"),
         error: Map.get(payload, "error"),
         artifact: artifact
       }}
    else
      false -> {:error, :invalid_history_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry_from_payload(_payload), do: {:error, :invalid_history_payload}

  defp artifact_from_payload(nil), do: {:ok, nil}

  defp artifact_from_payload(%{} = artifact) do
    with {:ok, status} <- decode_enum(Map.get(artifact, "status"), [:missing, :available, :error]),
         true <- is_binary(Map.get(artifact, "path")) || {:error, :invalid_history_artifact_path} do
      {:ok,
       %{
         path: Map.get(artifact, "path"),
         status: status,
         updated_at: Map.get(artifact, "updated_at"),
         size_bytes: Map.get(artifact, "size_bytes"),
         error: Map.get(artifact, "error")
       }}
    else
      false -> {:error, :invalid_history_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp artifact_from_payload(_payload), do: {:error, :invalid_history_payload}

  defp build_snapshot(entries, limit) do
    returned_entries = Enum.take(entries, limit)
    retained_count = length(entries)

    %Snapshot{
      status: :available,
      entries: returned_entries,
      returned_count: length(returned_entries),
      retained_count: retained_count,
      has_more?: retained_count > limit,
      counts: counts(entries),
      latest: List.first(entries),
      latest_by_action: %{
        preflight: Enum.find(entries, &(&1.action == :preflight)),
        run: Enum.find(entries, &(&1.action == :run))
      },
      error: nil
    }
  end

  defp missing_snapshot do
    %Snapshot{
      status: :missing,
      entries: [],
      returned_count: 0,
      retained_count: 0,
      has_more?: false,
      counts: counts([]),
      latest: nil,
      latest_by_action: %{preflight: nil, run: nil},
      error: nil
    }
  end

  defp error_snapshot(reason) do
    %Snapshot{
      status: :error,
      entries: [],
      returned_count: 0,
      retained_count: 0,
      has_more?: false,
      counts: counts([]),
      latest: nil,
      latest_by_action: %{preflight: nil, run: nil},
      error: reason
    }
  end

  defp counts(entries) do
    base = %{total: length(entries), succeeded: 0, failed: 0, escalated: 0, stopped: 0, start_failed: 0}

    Enum.reduce(entries, base, fn %Entry{outcome: outcome}, acc ->
      Map.update!(acc, outcome, &(&1 + 1))
    end)
  end

  defp build_entry(%Config{} = config, %RunSpec{} = run_spec, attrs) do
    started_at = Keyword.get(attrs, :started_at)
    finished_at = Keyword.get(attrs, :finished_at, iso_now())
    outcome = Keyword.fetch!(attrs, :outcome)

    %Entry{
      run_id: Keyword.fetch!(attrs, :run_id),
      workflow_name: run_spec.workflow_name,
      action: run_spec.action,
      outcome: outcome,
      runtime_surface: Keyword.get(attrs, :runtime_surface),
      branch: Keyword.get(attrs, :branch, config.default_branch),
      started_at: started_at,
      finished_at: finished_at,
      duration_ms: duration_ms(started_at, finished_at),
      summary: Keyword.get(attrs, :summary),
      requested_action: Keyword.get(attrs, :requested_action),
      runtime_status: Keyword.get(attrs, :runtime_status, RuntimeStateStore.status(config)),
      failure_kind: Keyword.get(attrs, :failure_kind),
      error: serialize_error(Keyword.get(attrs, :error)),
      artifact: artifact_metadata(config, run_spec.workflow_name, run_spec.action, outcome, started_at)
    }
  end

  defp artifact_metadata(%Config{}, _workflow_name, _action, :start_failed, _started_at), do: nil

  defp artifact_metadata(%Config{} = config, workflow_name, action, _outcome, started_at) do
    path = workflow_artifact_path(config, workflow_name, action)

    case PathPolicy.validate_owned_path(config, path, :runtime) do
      {:ok, validated_path} ->
        case File.lstat(validated_path, time: :posix) do
          {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
            updated_at = iso_from_unix(mtime)

            if artifact_fresh_for_attempt?(updated_at, started_at) do
              %{path: validated_path, status: :available, updated_at: updated_at, size_bytes: size, error: nil}
            else
              nil
            end

          {:ok, %File.Stat{type: :symlink}} ->
            %{path: validated_path, status: :error, updated_at: nil, size_bytes: nil, error: inspect({:symlink_artifact_path, validated_path})}

          {:ok, %File.Stat{type: type}} ->
            %{path: validated_path, status: :error, updated_at: nil, size_bytes: nil, error: inspect({:unsupported_artifact_type, type})}

          {:error, :enoent} ->
            %{path: validated_path, status: :missing, updated_at: nil, size_bytes: nil, error: nil}

          {:error, reason} ->
            %{path: validated_path, status: :error, updated_at: nil, size_bytes: nil, error: inspect(reason)}
        end

      {:error, reason} ->
        %{path: path, status: :error, updated_at: nil, size_bytes: nil, error: inspect(reason)}
    end
  end

  defp workflow_artifact_path(%Config{} = config, workflow_name, :preflight) do
    Path.join([config.runtime_dir, "workflows", workflow_name, "last-preflight.txt"])
  end

  defp workflow_artifact_path(%Config{} = config, workflow_name, :run) do
    Path.join([config.runtime_dir, "workflows", workflow_name, "last-run.txt"])
  end

  defp entry_payload(%Entry{} = entry) do
    %{
      "run_id" => entry.run_id,
      "workflow_name" => entry.workflow_name,
      "action" => Atom.to_string(entry.action),
      "outcome" => Atom.to_string(entry.outcome),
      "runtime_surface" => entry.runtime_surface,
      "branch" => entry.branch,
      "started_at" => entry.started_at,
      "finished_at" => entry.finished_at,
      "duration_ms" => entry.duration_ms,
      "summary" => entry.summary,
      "requested_action" => entry.requested_action,
      "runtime_status" => entry.runtime_status,
      "failure_kind" => entry.failure_kind,
      "error" => entry.error,
      "artifact" => artifact_payload(entry.artifact)
    }
  end

  defp artifact_payload(nil), do: nil

  defp artifact_payload(artifact) do
    %{
      "path" => artifact.path,
      "status" => Atom.to_string(artifact.status),
      "updated_at" => artifact.updated_at,
      "size_bytes" => artifact.size_bytes,
      "error" => serialize_error(artifact.error)
    }
  end

  defp validate_workflow_name(workflow_name) do
    case RunSpec.workflow(:run, workflow_name) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_enum(value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: {:ok, atom}, else: {:error, :invalid_history_payload}
  rescue
    ArgumentError -> {:error, :invalid_history_payload}
  end

  defp decode_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_history_payload}
  end

  defp decode_enum(_value, _allowed), do: {:error, :invalid_history_payload}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @retained_entries)
  defp normalize_limit(_limit), do: @default_fetch_limit

  defp artifact_fresh_for_attempt?(_updated_at, nil), do: true
  defp artifact_fresh_for_attempt?(nil, _started_at), do: false

  defp artifact_fresh_for_attempt?(updated_at, started_at) do
    with {:ok, updated_dt, _} <- DateTime.from_iso8601(updated_at),
         {:ok, started_dt, _} <- DateTime.from_iso8601(started_at) do
      DateTime.compare(updated_dt, started_dt) in [:gt, :eq]
    else
      _ -> true
    end
  end

  defp duration_ms(nil, _finished_at), do: nil
  defp duration_ms(_started_at, nil), do: nil

  defp duration_ms(started_at, finished_at) do
    with {:ok, started_dt, _} <- DateTime.from_iso8601(started_at),
         {:ok, finished_dt, _} <- DateTime.from_iso8601(finished_at) do
      max(DateTime.diff(finished_dt, started_dt, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp iso_from_unix(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!(:second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp serialize_error(nil), do: nil
  defp serialize_error(error) when is_binary(error), do: error
  defp serialize_error(error), do: inspect(error)

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workflow"
      sanitized -> sanitized
    end
  end
end
