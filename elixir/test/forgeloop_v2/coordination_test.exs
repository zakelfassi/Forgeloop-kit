defmodule ForgeloopV2.CoordinationTest do
  use ForgeloopV2.TestSupport

  test "parses rich question sections and ignores guidance headings" do
    repo =
      create_repo_fixture!(
        questions: """
        # Forgeloop Questions

        ## How to Answer
        1. Update the matching question below.

        ## Q-200 (2026-03-06 12:00:00)
        **Category**: blocked
        **Question**: Need a human call
        **Status**: ⏳ Awaiting response

        **Suggested action**: Please review the draft.
        **Suggested command**: `gh pr create --fill`
        **Escalation log**: `ESCALATIONS.md`
        **Evidence**: `logs/build.log`

        **Answer**:

        ---

        ## Q-150 (2026-03-05 10:00:00)
        **Category**: decision
        **Question**: Ship it?
        **Status**: ✅ Answered

        **Answer**:
        Yes.

        ---

        ## Q-175
        **Question**: Wrap this up
        **Status**: Resolved

        **Answer**:
        Done.

        ---

        ## Q-300
        **Question**: Partial write
        """
      )

    config = config_for!(repo.repo_root)

    assert {:ok, questions} = Coordination.read_questions(config)
    assert Enum.map(questions, & &1.id) == ["Q-200", "Q-150", "Q-175", "Q-300"]

    assert %Coordination.Question{
             opened_at: "2026-03-06 12:00:00",
             category: "blocked",
             question: "Need a human call",
             status_kind: :awaiting_response,
             suggested_action: "Please review the draft.",
             suggested_command: "gh pr create --fill",
             escalation_log: "ESCALATIONS.md",
             evidence: "logs/build.log",
             answer: nil
           } = Enum.at(questions, 0)

    assert %Coordination.Question{status_kind: :answered, answer: "Yes."} = Enum.at(questions, 1)
    assert %Coordination.Question{status_kind: :resolved, answer: "Done."} = Enum.at(questions, 2)
    assert %Coordination.Question{status_kind: :unknown} = Enum.at(questions, 3)

    assert Coordination.unanswered_question_ids(config) == ["Q-200"]
  end

  test "parses compact blocker-hash question statuses and sorts unanswered ids" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-3
        - ⏳ Awaiting response

        ## Q-2
        - ✅ Answered

        ## Q-1
        - ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)

    assert {:ok, questions} = Coordination.read_questions(config)

    assert Enum.map(questions, &{&1.id, &1.status_kind}) == [
             {"Q-3", :awaiting_response},
             {"Q-2", :answered},
             {"Q-1", :awaiting_response}
           ]

    assert Coordination.unanswered_question_ids(config) == ["Q-1", "Q-3"]
  end

  test "does not infer answered or resolved state from non-status prose" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-400
        **Question**: Why is this unanswered?
        **Evidence**: `logs/unresolved-case.txt`
        """
      )

    config = config_for!(repo.repo_root)

    assert {:ok, [question]} = Coordination.read_questions(config)
    assert question.id == "Q-400"
    assert question.status_kind == :unknown
    assert Coordination.unanswered_question_ids(config) == []
  end

  test "parses escalation sections for future ui surfaces" do
    repo =
      create_repo_fixture!(
        escalations: """
        ## E-12345 (2026-03-06 11:00:00)
        - Kind: `spin`
        - Repeat count: `3`
        - Requested action: `issue`
        - Summary: CI gate failed on main
        - Evidence: `logs/error.txt`
        - Host: `builder-1`

        ### Draft
        Forgeloop hit the same `spin` failure 3 times and paused itself.

        Suggested next move: file an issue.
       
        ---
        """
      )

    config = config_for!(repo.repo_root)

    assert {:ok, [entry]} = Coordination.read_escalations(config)
    assert entry.id == "E-12345"
    assert entry.opened_at == "2026-03-06 11:00:00"
    assert entry.kind == "spin"
    assert entry.repeat_count == 3
    assert entry.requested_action == "issue"
    assert entry.summary == "CI gate failed on main"
    assert entry.evidence == "logs/error.txt"
    assert entry.host == "builder-1"
    assert entry.draft =~ "paused itself"
  end

  test "missing coordination files return missing while unanswered ids stay fail-open" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    File.rm!(config.questions_file)
    File.rm!(config.escalations_file)

    assert :missing = Coordination.read_questions(config)
    assert :missing = Coordination.read_escalations(config)
    assert [] = Coordination.unanswered_question_ids(config)
  end
end
