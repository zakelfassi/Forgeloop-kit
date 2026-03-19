defmodule ForgeloopV2.FailureTrackerTest do
  use ForgeloopV2.TestSupport

  test "retries below threshold and escalates at threshold" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root, failure_escalate_after: 2)
    evidence_file = Path.join(repo.repo_root, "evidence.txt")
    File.write!(evidence_file, "CI still failing on the same command\n")

    assert {:retry, 1} =
             FailureTracker.handle(config, %{
               kind: "ci",
               summary: "CI gate failed on main",
               evidence_file: evidence_file,
               requested_action: "issue",
               surface: "loop",
               mode: "build",
               branch: "main"
             })

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "blocked"

    assert {:stop, 2} =
             FailureTracker.handle(config, %{
               kind: "ci",
               summary: "CI gate failed on main",
               evidence_file: evidence_file,
               requested_action: "issue",
               surface: "loop",
               mode: "build",
               branch: "main"
             })

    assert File.read!(config.requests_file) =~ "[PAUSE]"
  end

  test "resets signature count when failure changes and tolerates corrupt state" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root, failure_escalate_after: 3)
    File.mkdir_p!(config.v2_state_dir)
    File.write!(Path.join(config.v2_state_dir, "failure-state.json"), "{not-json")

    assert {:ok, 1} = FailureTracker.record(config, "ci", "CI gate failed on main", nil)
    assert {:ok, 1} = FailureTracker.record(config, "ci", "Different failure", nil)
  end
end
