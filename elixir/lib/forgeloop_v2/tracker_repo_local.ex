defmodule ForgeloopV2.Tracker.RepoLocal.Overview do
  @moduledoc false

  alias ForgeloopV2.Tracker.Issue

  @type source :: %{
          kind: atom(),
          label: String.t(),
          path: String.t(),
          canonical?: boolean(),
          phase: String.t()
        }

  @type counts :: %{
          total: non_neg_integer(),
          backlog: non_neg_integer(),
          workflows: non_neg_integer(),
          ready: non_neg_integer(),
          blocked: non_neg_integer()
        }

  @type t :: %__MODULE__{
          sources: %{backlog: source(), workflows: source()},
          counts: counts(),
          issues: [Issue.t()]
        }

  defstruct [:sources, :counts, issues: []]
end

defmodule ForgeloopV2.Tracker.RepoLocal do
  @moduledoc false
  @behaviour ForgeloopV2.Tracker

  alias ForgeloopV2.{Config, PlanStore, WorkflowService}
  alias ForgeloopV2.PlanStore.Backlog
  alias ForgeloopV2.PlanStore.Item
  alias ForgeloopV2.Tracker.Issue
  alias ForgeloopV2.Tracker.RepoLocal.Overview
  alias ForgeloopV2.WorkflowService.WorkflowSummary

  @state_ready "ready"
  @state_blocked "blocked"

  @spec overview(Config.t()) :: {:ok, Overview.t()} | {:error, term()}
  def overview(%Config{} = config) do
    with {:ok, %Backlog{} = backlog} <- PlanStore.summary(config),
         {:ok, workflow_overview} <- WorkflowService.overview(config) do
      overview(config, backlog, workflow_overview)
    end
  end

  @spec overview(Config.t(), Backlog.t(), WorkflowService.Overview.t()) :: {:ok, Overview.t()}
  def overview(%Config{} = config, %Backlog{} = backlog, %WorkflowService.Overview{} = workflow_overview) do
    plan_issues = project_plan_issues(backlog)
    workflow_issues = Enum.map(workflow_overview.workflows, &project_workflow_issue(config, &1))
    issues = plan_issues ++ workflow_issues

    {:ok,
     %Overview{
       sources: %{
         backlog: backlog.source,
         workflows: workflow_source(config)
       },
       counts: %{
         total: length(issues),
         backlog: length(plan_issues),
         workflows: length(workflow_issues),
         ready: Enum.count(issues, &(&1.state == @state_ready)),
         blocked: Enum.count(issues, &(&1.state == @state_blocked))
       },
       issues: issues
     }}
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with_runtime_config(&fetch_candidate_issues/1)
  end

  @spec fetch_candidate_issues(Config.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(%Config{} = config) do
    with {:ok, %Overview{issues: issues}} <- overview(config) do
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    with_runtime_config(&fetch_issues_by_states(&1, states))
  end

  @spec fetch_issues_by_states(Config.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(%Config{} = config, states) when is_list(states) do
    wanted =
      states
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- fetch_candidate_issues(config) do
      {:ok, Enum.filter(issues, fn %Issue{state: state} -> MapSet.member?(wanted, normalize_state(state)) end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with_runtime_config(&fetch_issue_states_by_ids(&1, issue_ids))
  end

  @spec fetch_issue_states_by_ids(Config.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%Config{} = config, issue_ids) when is_list(issue_ids) do
    wanted = MapSet.new(issue_ids)

    with {:ok, issues} <- fetch_candidate_issues(config) do
      {:ok, Enum.filter(issues, fn %Issue{id: id} -> MapSet.member?(wanted, id) end)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: {:error, :read_only_tracker}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: {:error, :read_only_tracker}

  defp with_runtime_config(fun) do
    case Application.get_env(:forgeloop_v2, :tracker_repo_local_config) do
      %Config{} = config -> fun.(config)
      opts when is_list(opts) -> with {:ok, config} <- Config.load(opts), do: fun.(config)
      nil -> {:error, :tracker_repo_local_config_not_set}
      other -> {:error, {:invalid_tracker_repo_local_config, other}}
    end
  end

  defp workflow_source(%Config{} = config) do
    %{
      kind: :workflow_catalog,
      label: Path.basename(config.workflow_dir),
      path: config.workflow_dir,
      canonical?: false,
      phase: "phase1"
    }
  end

  defp project_plan_issues(%Backlog{read_status: :missing} = backlog) do
    [plan_alert_issue(backlog, "Canonical backlog missing", "The configured implementation plan file is missing, so the control plane fails closed and still reports pending work.")]
  end

  defp project_plan_issues(%Backlog{read_status: :unreadable} = backlog) do
    [plan_alert_issue(backlog, "Canonical backlog unreadable", "The configured implementation plan path could not be read as a plan file, so the control plane fails closed and still reports pending work.")]
  end

  defp project_plan_issues(%Backlog{items: items, source: source}) do
    updated_at = timestamp_for_path(source.path)

    items
    |> group_pending_plan_items()
    |> Enum.map(fn %{parent: parent, children: children} ->
      %Issue{
        id: plan_issue_id(parent),
        identifier: "#{source.label}:#{parent.line_number}",
        title: parent.text,
        description: plan_description(source, parent, children),
        state: @state_ready,
        workflow_state: :plan_item,
        url: nil,
        labels: plan_labels(parent),
        assignees: [],
        created_at: updated_at,
        updated_at: updated_at
      }
    end)
  end

  defp group_pending_plan_items(items) do
    {groups, current_group} =
      Enum.reduce(items, {[], nil}, fn item, {groups, current_group} ->
        cond do
          item.depth == 0 ->
            {flush_group(groups, current_group), %{parent: item, children: []}}

          is_nil(current_group) ->
            {groups, %{parent: item, children: []}}

          true ->
            {groups, %{current_group | children: current_group.children ++ [item]}}
        end
      end)

    flush_group(groups, current_group)
  end

  defp flush_group(groups, nil), do: groups
  defp flush_group(groups, current_group), do: groups ++ [current_group]

  defp project_workflow_issue(%Config{} = config, %WorkflowSummary{} = summary) do
    entry = summary.entry
    updated_at = workflow_updated_at(summary)
    state = workflow_state(summary)

    %Issue{
      id: workflow_issue_id(entry.name),
      identifier: "workflow:#{entry.name}",
      title: "Workflow pack: #{entry.name}",
      description: workflow_description(config, summary),
      state: state,
      workflow_state: :workflow_pack,
      url: nil,
      labels: workflow_labels(summary),
      assignees: [],
      created_at: updated_at,
      updated_at: updated_at
    }
  end

  defp workflow_updated_at(%WorkflowSummary{} = summary) do
    with iso when is_binary(iso) <- summary.latest_activity_at,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(iso) do
      datetime
    else
      _ ->
        entry = summary.entry
        latest_timestamp([entry.graph_file, entry.config_file, entry.root])
    end
  end

  defp workflow_state(%WorkflowSummary{} = summary) do
    statuses = [summary.preflight.status, summary.run.status]
    if Enum.any?(statuses, &(&1 == :error)), do: @state_blocked, else: @state_ready
  end

  defp plan_alert_issue(%Backlog{source: source}, title, description) do
    updated_at = timestamp_for_path(source.path)

    %Issue{
      id: "plan:alert",
      identifier: "#{source.label}:alert",
      title: title,
      description: description,
      state: @state_blocked,
      workflow_state: :backlog_alert,
      url: nil,
      labels: ["repo-local", "canonical-backlog", "phase1", "backlog-alert"],
      assignees: [],
      created_at: updated_at,
      updated_at: updated_at
    }
  end

  defp plan_issue_id(%Item{line_number: line_number}), do: "plan:#{line_number}"
  defp workflow_issue_id(name), do: "workflow:#{name}"

  defp plan_description(source, parent, children) do
    child_lines =
      children
      |> Enum.map(fn child -> "- [ ] #{child.text} (line #{child.line_number})" end)
      |> Enum.join("\n")

    [
      "Source: #{source.label}:#{parent.line_number}",
      if(parent.section, do: "Section: #{parent.section}", else: nil),
      "Depth: #{parent.depth}",
      if(child_lines != "", do: "Pending child items:\n#{child_lines}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp workflow_description(%Config{} = config, %WorkflowSummary{} = summary) do
    entry = summary.entry

    [
      "Workflow root: #{Path.relative_to(entry.root, config.repo_root)}",
      "Graph file: #{Path.relative_to(entry.graph_file, config.repo_root)}",
      "Config file: #{Path.relative_to(entry.config_file, config.repo_root)}",
      "Runner kind: #{entry.runner_kind}",
      if(entry.prompts_dir, do: "Prompts dir: #{Path.relative_to(entry.prompts_dir, config.repo_root)}", else: nil),
      if(entry.scripts_dir, do: "Scripts dir: #{Path.relative_to(entry.scripts_dir, config.repo_root)}", else: nil),
      "Preflight artifact: #{summary.preflight.status}",
      "Run artifact: #{summary.run.status}",
      if(summary.latest_activity_kind, do: "Latest activity: #{summary.latest_activity_kind} @ #{summary.latest_activity_at}", else: "Latest activity: none yet")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp plan_labels(%Item{} = item) do
    [
      "repo-local",
      "canonical-backlog",
      "phase1",
      "plan-item",
      if(item.section, do: "section:#{slugify(item.section)}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp workflow_labels(%WorkflowSummary{} = summary) do
    [
      "repo-local",
      "workflow-pack",
      "phase1",
      "runner:#{summary.entry.runner_kind}",
      if(summary.latest_activity_kind, do: "latest:#{summary.latest_activity_kind}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp timestamp_for_path(path), do: latest_timestamp([path])

  defp latest_timestamp(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> [mtime]
        _ -> []
      end
    end)
    |> case do
      [] -> DateTime.utc_now() |> DateTime.truncate(:second)
      values -> values |> Enum.max() |> DateTime.from_unix!() |> DateTime.truncate(:second)
    end
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
