defmodule ForgeloopV2.TrackerMemoryTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.Tracker
  alias ForgeloopV2.Tracker.Issue

  test "memory tracker fetches issues and emits comment/state events" do
    issues = [
      %Issue{id: "1", identifier: "repo#1", title: "Ready", state: "ready"},
      %Issue{id: "2", identifier: "repo#2", title: "Done", state: "done"}
    ]

    Application.put_env(:forgeloop_v2, :memory_tracker_issues, issues)
    Application.put_env(:forgeloop_v2, :memory_tracker_recipient, self())
    Application.put_env(:forgeloop_v2, :tracker_adapter, ForgeloopV2.Tracker.Memory)

    on_exit(fn ->
      Application.delete_env(:forgeloop_v2, :memory_tracker_issues)
      Application.delete_env(:forgeloop_v2, :memory_tracker_recipient)
      Application.delete_env(:forgeloop_v2, :tracker_adapter)
    end)

    assert {:ok, ^issues} = Tracker.fetch_candidate_issues()
    assert {:ok, [%Issue{id: "1"}]} = Tracker.fetch_issues_by_states(["ready"])
    assert {:ok, [%Issue{id: "2"}]} = Tracker.fetch_issue_states_by_ids(["2"])

    assert :ok = Tracker.create_comment("1", "hello")
    assert_receive {:memory_tracker_comment, "1", "hello"}

    assert :ok = Tracker.update_issue_state("1", "in_progress")
    assert_receive {:memory_tracker_state_update, "1", "in_progress"}
  end
end
