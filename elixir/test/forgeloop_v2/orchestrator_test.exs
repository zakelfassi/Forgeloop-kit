defmodule ForgeloopV2.OrchestratorTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.Orchestrator.{Context, Decision}

  test "decides pause, recover, escalate, plan, build, and idle branches" do
    assert %Decision{action: :pause} =
             Orchestrator.decide(%Context{
               pause_requested?: true,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}}
             })

    assert %Decision{action: :recover} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "paused",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}}
             })

    assert %Decision{action: :recover} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "awaiting-human",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}}
             })

    assert %Decision{action: :escalate_blocker} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: ["Q-1"],
               blocker_result: {:threshold_reached, %{count: 2}}
             })

    assert %Decision{action: :plan, consume_replan?: true} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: true,
               needs_build?: true,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}}
             })

    assert %Decision{action: :build} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: true,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}}
             })

    assert %Decision{action: :idle, persist_idle?: false} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "awaiting-human",
               unanswered_question_ids: ["Q-1"],
               blocker_result: {:tracking, %{count: 1}}
             })
  end
end
