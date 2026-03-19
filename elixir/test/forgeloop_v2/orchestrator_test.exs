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

  test "build_context routes plan and question reads through structured readers" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ] Build repo-local UI shell
        - [x] Keep GH issue fallback documented
        """,
        questions: """
        # Forgeloop Questions

        ## How to Answer
        Update the matching question below.

        ## Q-2
        - ✅ Answered

        ## Q-1
        - ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    context = Orchestrator.build_context(config)

    assert context.needs_build?
    assert context.unanswered_question_ids == ["Q-1"]
    assert match?({:tracking, %{count: 1, ids: ["Q-1"]}}, context.blocker_result)
  end
end
