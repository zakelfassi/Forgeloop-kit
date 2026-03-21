defmodule ForgeloopV2.Tracker.Issue do
  @moduledoc false

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :state,
    :workflow_state,
    :url,
    labels: [],
    assignees: [],
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          state: String.t() | nil,
          workflow_state: atom() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          assignees: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec normalize(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = issue) do
    validate(issue)
  end

  def normalize(issue) when is_map(issue) do
    normalized = %__MODULE__{
      id: string_or_nil(issue[:id] || issue["id"]),
      identifier: string_or_nil(issue[:identifier] || issue["identifier"]),
      title: string_or_nil(issue[:title] || issue["title"]),
      description: string_or_nil(issue[:description] || issue["description"]),
      state: string_or_nil(issue[:state] || issue["state"]),
      workflow_state: issue[:workflow_state] || issue["workflow_state"],
      url: string_or_nil(issue[:url] || issue["url"]),
      labels: normalize_string_list(issue[:labels] || issue["labels"] || []),
      assignees: normalize_string_list(issue[:assignees] || issue["assignees"] || []),
      created_at: normalize_datetime(issue[:created_at] || issue["created_at"]),
      updated_at: normalize_datetime(issue[:updated_at] || issue["updated_at"])
    }

    validate(normalized)
  end

  defp validate(%__MODULE__{} = issue) do
    required = %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      updated_at: issue.updated_at
    }

    missing =
      required
      |> Enum.filter(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(&elem(&1, 0))

    if missing == [] do
      {:ok, issue}
    else
      {:error, {:invalid_tracker_issue, missing}}
    end
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value), do: to_string(value)

  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(_values), do: []

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil
end

defmodule ForgeloopV2.Tracker do
  @moduledoc false

  alias ForgeloopV2.Tracker.Issue

  @callback fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, issues} <- adapter().fetch_candidate_issues() do
      normalize_issues(issues)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- adapter().fetch_issues_by_states(states) do
      normalize_issues(issues)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    with {:ok, issues} <- adapter().fetch_issue_states_by_ids(issue_ids) do
      normalize_issues(issues)
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: adapter().create_comment(issue_id, body)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: adapter().update_issue_state(issue_id, state_name)

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:forgeloop_v2, :tracker_adapter, ForgeloopV2.Tracker.Memory)
  end

  defp normalize_issues(issues) when is_list(issues) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case Issue.normalize(issue) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule ForgeloopV2.Tracker.Service do
  @moduledoc false

  alias ForgeloopV2.Config
  alias ForgeloopV2.Tracker
  alias ForgeloopV2.Tracker.Issue
  alias ForgeloopV2.Tracker.RepoLocal

  @spec list_candidate_work() :: {:ok, [Issue.t()]} | {:error, term()}
  def list_candidate_work, do: Tracker.fetch_candidate_issues()

  @spec refresh_issue_snapshots([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def refresh_issue_snapshots(issue_ids), do: Tracker.fetch_issue_states_by_ids(issue_ids)

  @spec repo_local_overview(Config.t()) :: {:ok, RepoLocal.Overview.t()} | {:error, term()}
  def repo_local_overview(%Config{} = config), do: RepoLocal.overview(config)

  @spec repo_local_overview(Config.t(), ForgeloopV2.PlanStore.Backlog.t(), ForgeloopV2.WorkflowService.Overview.t()) ::
          {:ok, RepoLocal.Overview.t()}
  def repo_local_overview(%Config{} = config, %ForgeloopV2.PlanStore.Backlog{} = backlog, %ForgeloopV2.WorkflowService.Overview{} = workflows) do
    RepoLocal.overview(config, backlog, workflows)
  end

  @spec transition_issue_after_outcome(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def transition_issue_after_outcome(issue_id, outcome) do
    Tracker.update_issue_state(issue_id, normalize_outcome(outcome))
  end

  @spec append_progress_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def append_progress_comment(issue_id, body), do: Tracker.create_comment(issue_id, body)

  defp normalize_outcome(:completed), do: "done"
  defp normalize_outcome(:blocked), do: "blocked"
  defp normalize_outcome(:in_progress), do: "in_progress"
  defp normalize_outcome(value) when is_binary(value), do: value
  defp normalize_outcome(value), do: to_string(value)
end

defmodule ForgeloopV2.Tracker.Memory do
  @moduledoc false
  @behaviour ForgeloopV2.Tracker

  alias ForgeloopV2.Tracker.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: issue_entries()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    wanted =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- issue_entries() do
      {:ok,
       Enum.filter(issues, fn %Issue{state: state} ->
         MapSet.member?(wanted, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted = MapSet.new(issue_ids)

    with {:ok, issues} <- issue_entries() do
      {:ok, Enum.filter(issues, fn %Issue{id: id} -> MapSet.member?(wanted, id) end)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:forgeloop_v2, :memory_tracker_issues, [])
  end

  defp issue_entries do
    configured_issues()
    |> Enum.reduce_while({:ok, []}, fn issue, {:ok, acc} ->
      case Issue.normalize(issue) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_event(message) do
    case Application.get_env(:forgeloop_v2, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
