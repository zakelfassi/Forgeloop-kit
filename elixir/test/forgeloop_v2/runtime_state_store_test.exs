defmodule ForgeloopV2.RuntimeStateStoreTest do
  use ForgeloopV2.TestSupport

  test "reads missing state and preserves previous status across writes" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert :missing = RuntimeStateStore.read(config)

    assert {:ok, state} =
             RuntimeStateStore.write(config, %{
               status: "awaiting-human",
               transition: "escalated",
               surface: "loop",
               mode: "build",
               reason: "CI gate failed on main",
               requested_action: "issue",
               branch: "main"
             })

    assert state.status == "awaiting-human"
    assert state.transition == "escalated"
    assert state.requested_action == "issue"

    assert {:ok, _} =
             RuntimeStateStore.write(config, %{
               status: "recovered",
               transition: "recovered",
               surface: "loop",
               mode: "build",
               reason: "Operator cleared pause",
               requested_action: "",
               branch: "main"
             })

    assert {:ok, state} =
             RuntimeStateStore.write(config, %{
               status: "idle",
               transition: "completed",
               surface: "loop",
               mode: "build",
               reason: "Loop completed after recovery",
               requested_action: "",
               branch: "main"
             })

    assert state.status == "idle"
    assert state.previous_status == "recovered"
    assert state.transition == "completed"
  end
end
