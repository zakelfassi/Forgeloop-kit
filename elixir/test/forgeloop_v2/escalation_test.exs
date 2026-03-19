defmodule ForgeloopV2.EscalationTest do
  use ForgeloopV2.TestSupport

  test "writes pause/question/escalation artifacts and runtime state" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    evidence_file = Path.join(repo.repo_root, "evidence.txt")
    File.write!(evidence_file, "CI still failing on the same command\n")

    assert :ok = ControlFiles.append_pause_flag(config)
    assert :ok = ControlFiles.append_pause_flag(config)

    assert {:ok, %{question_id: question_id, escalation_id: escalation_id}} =
             Escalation.escalate(config, %{
               kind: "ci",
               summary: "CI gate failed on main",
               requested_action: "issue",
               evidence_file: evidence_file,
               repeat_count: 3,
               surface: "loop",
               mode: "build",
               branch: "main",
               id: "12345"
             })

    assert question_id == "Q-12345"
    assert escalation_id == "E-12345"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.questions_file) =~ "Forgeloop stopped after repeated `ci` failure (3 x): CI gate failed on main"
    assert File.read!(config.escalations_file) =~ "Suggested command"

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert state.transition == "escalated"
    assert state.requested_action == "issue"
  end
end
