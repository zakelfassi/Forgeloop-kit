defmodule ForgeloopV2.RunSpec do
  @moduledoc false

  @type lane :: :checklist | :workflow
  @type action :: :plan | :build | :preflight | :run

  defstruct [:lane, :action, :workflow_name]

  @type t :: %__MODULE__{
          lane: lane(),
          action: action(),
          workflow_name: String.t() | nil
        }

  @workflow_name_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/

  @spec checklist(:plan | :build) :: {:ok, t()} | {:error, term()}
  def checklist(action) when action in [:plan, :build] do
    {:ok, %__MODULE__{lane: :checklist, action: action, workflow_name: nil}}
  end

  def checklist(other), do: {:error, {:invalid_mode, other}}

  @spec workflow(:preflight | :run, String.t()) :: {:ok, t()} | {:error, term()}
  def workflow(action, workflow_name) when action in [:preflight, :run] and is_binary(workflow_name) do
    if String.match?(workflow_name, @workflow_name_pattern) do
      {:ok, %__MODULE__{lane: :workflow, action: action, workflow_name: workflow_name}}
    else
      {:error, {:invalid_workflow_name, workflow_name}}
    end
  end

  def workflow(other, _workflow_name), do: {:error, {:invalid_workflow_action, other}}

  @spec runtime_mode(t()) :: String.t()
  def runtime_mode(%__MODULE__{lane: :checklist, action: action}), do: Atom.to_string(action)
  def runtime_mode(%__MODULE__{lane: :workflow, action: :preflight}), do: "workflow-preflight"
  def runtime_mode(%__MODULE__{lane: :workflow, action: :run}), do: "workflow-run"

  @spec workspace_kind(t()) :: String.t()
  def workspace_kind(%__MODULE__{lane: :checklist}), do: "babysitter"
  def workspace_kind(%__MODULE__{lane: :workflow}), do: "workflow"

  @spec lane_string(t()) :: String.t()
  def lane_string(%__MODULE__{lane: lane}), do: Atom.to_string(lane)

  @spec action_string(t()) :: String.t()
  def action_string(%__MODULE__{action: action}), do: Atom.to_string(action)

  @spec requested_action(t(), String.t()) :: String.t()
  def requested_action(%__MODULE__{lane: :workflow}, _checklist_default_action), do: "review"
  def requested_action(%__MODULE__{lane: :checklist}, checklist_default_action), do: checklist_default_action

  @spec same_instance?(t(), t()) :: boolean()
  def same_instance?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.lane == right.lane and left.action == right.action and left.workflow_name == right.workflow_name
  end
end
