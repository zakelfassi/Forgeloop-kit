defmodule ForgeloopV2.BlockerDetectorTest do
  use ForgeloopV2.TestSupport

  test "tracks repeated unanswered blockers and resets when cleared" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1 (2026-03-05 00:00:00)
        **Category**: blocked
        **Question**: Human input required
        **Status**: ⏳ Awaiting response

        **Answer**:
        """
      )

    config = config_for!(repo.repo_root, max_blocked_iterations: 2)

    assert {:tracking, %{count: 1, ids: ["Q-1"]}} = BlockerDetector.check(config)
    assert {:threshold_reached, %{count: 2, ids: ["Q-1"]}} = BlockerDetector.check(config)

    File.write!(config.questions_file, "")
    assert {:clear, %{count: 0}} = BlockerDetector.check(config)
  end
end
