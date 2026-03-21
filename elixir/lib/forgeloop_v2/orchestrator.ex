defmodule ForgeloopV2.Orchestrator.Context do
  @moduledoc false

  defstruct [
    :pause_requested?,
    :replan_requested?,
    :needs_build?,
    :runtime_status,
    :unanswered_question_ids,
    :blocker_result
  ]
end

defmodule ForgeloopV2.Orchestrator.Decision do
  @moduledoc false

  defstruct [:action, :reason, consume_replan?: false, persist_idle?: true]
end

defmodule ForgeloopV2.Orchestrator do
  @moduledoc false

  alias ForgeloopV2.{
    BlockerDetector,
    Config,
    ControlFiles,
    Orchestrator.Context,
    PlanStore,
    Orchestrator.Decision,
    RuntimeRecovery,
    RuntimeStateStore
  }

  @spec build_context(Config.t()) :: Context.t()
  def build_context(%Config{} = config) do
    %Context{
      pause_requested?: ControlFiles.has_flag?(config, "PAUSE"),
      replan_requested?: ControlFiles.has_flag?(config, "REPLAN"),
      needs_build?: needs_build?(config),
      runtime_status: RuntimeStateStore.status(config),
      unanswered_question_ids: ControlFiles.unanswered_question_ids(config),
      blocker_result: BlockerDetector.check(config)
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
        %Decision{action: :plan, reason: "Replan requested", consume_replan?: true}

      context.needs_build? ->
        %Decision{action: :build, reason: "Implementation plan still has pending work"}

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

  defp idle_reason(%Context{runtime_status: "awaiting-human"}), do: "Awaiting human response"
  defp idle_reason(_context), do: "No pending work"

  defp needs_build?(config) do
    {:ok, backlog} = PlanStore.summary(config)
    backlog.needs_build?
  end
end
