defmodule ForgeloopV2.Orchestrator.Context do
  @moduledoc false

  defstruct [
    :pause_requested?,
    :replan_requested?,
    :needs_build?,
    :runtime_status,
    :unanswered_question_ids,
    :blocker_result,
    :workflow_requested?,
    :workflow_run_spec,
    :workflow_request_error
  ]
end

defmodule ForgeloopV2.Orchestrator.Decision do
  @moduledoc false

  defstruct [:action, :reason, :run_spec, :error, :consume_flag, persist_idle?: true]
end

defmodule ForgeloopV2.Orchestrator do
  @moduledoc false

  alias ForgeloopV2.{
    BlockerDetector,
    Config,
    ControlFiles,
    Orchestrator.Context,
    Orchestrator.Decision,
    PlanStore,
    RunSpec,
    RuntimeRecovery,
    RuntimeStateStore
  }

  @spec build_context(Config.t()) :: Context.t()
  def build_context(%Config{} = config) do
    %{requested?: workflow_requested?, run_spec: workflow_run_spec, error: workflow_request_error} = workflow_request(config)

    %Context{
      pause_requested?: ControlFiles.has_flag?(config, "PAUSE"),
      replan_requested?: ControlFiles.has_flag?(config, "REPLAN"),
      needs_build?: needs_build?(config),
      runtime_status: RuntimeStateStore.status(config),
      unanswered_question_ids: ControlFiles.unanswered_question_ids(config),
      blocker_result: BlockerDetector.check(config),
      workflow_requested?: workflow_requested?,
      workflow_run_spec: workflow_run_spec,
      workflow_request_error: workflow_request_error
    }
  end

  @spec decide(Context.t()) :: Decision.t()
  def decide(%Context{} = context) do
    recovery = recovery_result(context)

    cond do
      context.pause_requested? ->
        %Decision{action: :pause, reason: "Pause requested via REQUESTS.md"}

      match?({:recover, _}, recovery) ->
        %Decision{action: :recover, reason: recovery_reason(recovery)}

      match?({:threshold_reached, _}, context.blocker_result) ->
        %Decision{action: :escalate_blocker, reason: "Repeated unanswered blocker threshold reached"}

      context.replan_requested? ->
        %Decision{
          action: :plan,
          reason: "Replan requested",
          run_spec: checklist!(:plan),
          consume_flag: "REPLAN"
        }

      context.needs_build? ->
        %Decision{
          action: :build,
          reason: "Implementation plan still has pending work",
          run_spec: checklist!(:build)
        }

      context.workflow_requested? and match?(%RunSpec{}, context.workflow_run_spec) ->
        %Decision{
          action: :workflow,
          reason: workflow_reason(context.workflow_run_spec),
          run_spec: context.workflow_run_spec,
          consume_flag: "WORKFLOW"
        }

      context.workflow_requested? ->
        %Decision{
          action: :workflow_error,
          reason: workflow_error_reason(context.workflow_request_error),
          error: context.workflow_request_error
        }

      true ->
        %Decision{
          action: :idle,
          reason: idle_reason(context),
          persist_idle?: context.runtime_status not in ["awaiting-human"]
        }
    end
  end

  defp recovery_result(%Context{pause_requested?: true}), do: :no_recovery

  defp recovery_result(%Context{} = context) do
    RuntimeRecovery.evaluate(context.runtime_status, context.unanswered_question_ids,
      allow_blocked?: false
    )
  end

  defp recovery_reason({:recover, :paused}), do: "Operator pause cleared; daemon may resume"

  defp recovery_reason({:recover, :awaiting_human_cleared}),
    do: "Escalation artifacts are cleared; daemon may resume"

  defp workflow_reason(%RunSpec{action: action, workflow_name: workflow_name}) do
    "Daemon workflow #{action} requested for #{workflow_name}"
  end

  defp workflow_error_reason(reason) do
    "Daemon workflow request is invalid: #{format_workflow_request_error(reason)}"
  end

  defp format_workflow_request_error(:missing_daemon_workflow_name), do: "missing FORGELOOP_DAEMON_WORKFLOW_NAME"

  defp format_workflow_request_error({:invalid_daemon_workflow_action, value}),
    do: "invalid FORGELOOP_DAEMON_WORKFLOW_ACTION=#{inspect(value)}"

  defp format_workflow_request_error({:invalid_workflow_name, workflow_name}),
    do: "invalid workflow name #{inspect(workflow_name)}"

  defp format_workflow_request_error(reason), do: inspect(reason)

  defp idle_reason(%Context{runtime_status: "awaiting-human"}), do: "Awaiting human response"
  defp idle_reason(_context), do: "No pending work"

  defp needs_build?(config) do
    {:ok, backlog} = PlanStore.summary(config)
    backlog.needs_build?
  end

  defp checklist!(action) do
    {:ok, run_spec} = RunSpec.checklist(action)
    run_spec
  end

  @spec workflow_request(Config.t()) :: %{requested?: boolean(), run_spec: RunSpec.t() | nil, error: term() | nil}
  def workflow_request(%Config{} = config) do
    {requested?, run_spec, error} = resolve_workflow_request(config)
    %{requested?: requested?, run_spec: run_spec, error: error}
  end

  defp resolve_workflow_request(%Config{} = config) do
    if ControlFiles.has_flag?(config, "WORKFLOW") do
      case daemon_workflow_run_spec(config) do
        {:ok, run_spec} -> {true, run_spec, nil}
        {:error, reason} -> {true, nil, reason}
      end
    else
      {false, nil, nil}
    end
  end

  defp daemon_workflow_run_spec(%Config{} = config) do
    with {:ok, workflow_name} <- daemon_workflow_name(config),
         {:ok, action} <- daemon_workflow_action(config),
         {:ok, run_spec} <- RunSpec.workflow(action, workflow_name) do
      {:ok, run_spec}
    end
  end

  defp daemon_workflow_name(%Config{daemon_workflow_name: workflow_name}) when is_binary(workflow_name) and workflow_name != "",
    do: {:ok, workflow_name}

  defp daemon_workflow_name(_config), do: {:error, :missing_daemon_workflow_name}

  defp daemon_workflow_action(%Config{daemon_workflow_action: action}) when is_atom(action) do
    daemon_workflow_action(%Config{daemon_workflow_action: Atom.to_string(action)})
  end

  defp daemon_workflow_action(%Config{daemon_workflow_action: action}) when is_binary(action) do
    case String.downcase(String.trim(action)) do
      "preflight" -> {:ok, :preflight}
      "run" -> {:ok, :run}
      other -> {:error, {:invalid_daemon_workflow_action, other}}
    end
  end

  defp daemon_workflow_action(_config), do: {:error, {:invalid_daemon_workflow_action, nil}}
end
