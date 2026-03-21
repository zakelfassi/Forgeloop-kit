defmodule ForgeloopV2.OrchestratorTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.Orchestrator.{Context, Decision}
  alias ForgeloopV2.RunSpec

  test "decides pause, recover, escalate, plan, build, workflow, workflow-error, and idle branches" do
    assert %Decision{action: :pause} =
             Orchestrator.decide(%Context{
               pause_requested?: true,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: false
             })

    assert %Decision{action: :recover} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "paused",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: false
             })

    assert %Decision{action: :recover} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "awaiting-human",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: false
             })

    assert %Decision{action: :escalate_blocker} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: ["Q-1"],
               blocker_result: {:threshold_reached, %{count: 2}},
               workflow_requested?: false
             })

    assert %Decision{action: :plan, consume_flag: "REPLAN", run_spec: %RunSpec{action: :plan}} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: true,
               needs_build?: true,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: true,
               workflow_run_spec: %RunSpec{lane: :workflow, action: :preflight, workflow_name: "alpha"}
             })

    assert %Decision{action: :build, run_spec: %RunSpec{action: :build}} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: true,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: true,
               workflow_run_spec: %RunSpec{lane: :workflow, action: :preflight, workflow_name: "alpha"}
             })

    assert %Decision{
             action: :workflow,
             consume_flag: "WORKFLOW",
             run_spec: %RunSpec{lane: :workflow, action: :preflight, workflow_name: "alpha"}
           } =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: true,
               workflow_run_spec: %RunSpec{lane: :workflow, action: :preflight, workflow_name: "alpha"},
               workflow_request_error: nil
             })

    assert %Decision{action: :workflow_error, error: :missing_daemon_workflow_name} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "idle",
               unanswered_question_ids: [],
               blocker_result: {:clear, %{count: 0}},
               workflow_requested?: true,
               workflow_run_spec: nil,
               workflow_request_error: :missing_daemon_workflow_name
             })

    assert %Decision{action: :idle, persist_idle?: false} =
             Orchestrator.decide(%Context{
               pause_requested?: false,
               replan_requested?: false,
               needs_build?: false,
               runtime_status: "awaiting-human",
               unanswered_question_ids: ["Q-1"],
               blocker_result: {:tracking, %{count: 1}},
               workflow_requested?: false
             })
  end

  test "build_context routes plan, question, and daemon workflow reads through structured readers" do
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

    config = config_for!(repo.repo_root, daemon_workflow_name: "alpha", daemon_workflow_action: "preflight")
    File.write!(config.requests_file, "[WORKFLOW]\n")
    context = Orchestrator.build_context(config)

    assert context.needs_build?
    assert context.unanswered_question_ids == ["Q-1"]
    assert match?({:tracking, %{count: 1, ids: ["Q-1"]}}, context.blocker_result)
    assert context.workflow_requested?
    assert %RunSpec{lane: :workflow, action: :preflight, workflow_name: "alpha"} = context.workflow_run_spec
  end

  test "build_context records invalid daemon workflow requests without failing the rest of the context" do
    repo = create_repo_fixture!(plan_content: "# done\n", requests: "[WORKFLOW]\n")
    config = config_for!(repo.repo_root, daemon_workflow_name: "alpha", daemon_workflow_action: "launch")
    context = Orchestrator.build_context(config)

    assert context.workflow_requested?
    assert context.workflow_run_spec == nil
    assert context.workflow_request_error == {:invalid_daemon_workflow_action, "launch"}
  end
end
