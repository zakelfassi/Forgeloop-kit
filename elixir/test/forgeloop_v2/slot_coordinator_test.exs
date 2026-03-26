defmodule ForgeloopV2.SlotCoordinatorTest do
  use ForgeloopV2.TestSupport

  @shell_sleep """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "sleeping"
  sleep 30
  """

  test "starts parallel read slots in separate worktrees and keeps repo-root coordination files canonical" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true)

    {:ok, pid} = SlotCoordinator.start_link(config: config, name: nil)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    assert {:ok, first} =
             SlotCoordinator.start_slot(pid,
               lane: "checklist",
               action: "plan",
               runtime_surface: "ui"
             )

    assert {:ok, second} =
             SlotCoordinator.start_slot(pid,
               lane: "checklist",
               action: "plan",
               runtime_surface: "openclaw"
             )

    assert first.slot_id != second.slot_id

    wait_until(fn ->
      {:ok, payload} = SlotCoordinator.list_slots(pid)
      payload.counts.active >= 2
    end, 5_000)

    {:ok, root_runtime} = RuntimeStateStore.read(config)
    assert root_runtime.status == "running"
    assert root_runtime.mode == "slots"
    assert root_runtime.transition == "coordinating"
    assert Worktree.active_run_state(config) == :missing

    {:ok, owner_status} = ActiveRuntime.status(config)
    assert owner_status.live? == true
    assert owner_status.current["owner"] == "slots"

    {:ok, detail} = SlotCoordinator.fetch_slot(pid, first.slot_id)
    assert detail.slot_id == first.slot_id
    assert detail.runtime_surface == "ui"
    assert detail.coordination_paths.requests != config.requests_file
    assert detail.coordination_paths.questions != config.questions_file
    assert detail.coordination_paths.escalations != config.escalations_file
    assert detail.runtime_state["mode"] == "plan"
    assert is_binary(detail.worktree_path)

    assert File.read!(config.requests_file) == ""
    assert File.read!(config.questions_file) == ""
    assert File.read!(config.escalations_file) == ""

    assert {:ok, _} = SlotCoordinator.stop_slot(pid, first.slot_id, :pause)
    assert {:ok, _} = SlotCoordinator.stop_slot(pid, second.slot_id, :pause)

    wait_until(fn ->
      {:ok, payload} = SlotCoordinator.list_slots(pid)
      payload.counts.active == 0
    end, 5_000)

    {:ok, final_runtime} = RuntimeStateStore.read(config)
    assert final_runtime.status == "idle"
    assert final_runtime.mode == "slots"

    {:ok, final_owner_status} = ActiveRuntime.status(config)
    assert final_owner_status.live? == false
  end

  test "enforces the configured read-slot limit" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true, max_read_slots: 1)

    {:ok, pid} = SlotCoordinator.start_link(config: config, name: nil)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    assert {:ok, first} =
             SlotCoordinator.start_slot(pid,
               lane: "checklist",
               action: "plan",
               runtime_surface: "service"
             )

    assert {:error, {:slot_capacity_reached, :read, 1}} =
             SlotCoordinator.start_slot(pid,
               lane: "checklist",
               action: "plan",
               runtime_surface: "ui"
             )

    assert {:ok, _} = SlotCoordinator.stop_slot(pid, first.slot_id, :pause)
    wait_until(fn ->
      {:ok, payload} = SlotCoordinator.list_slots(pid)
      payload.counts.active == 0
    end, 5_000)
  end

  test "defers write-class slot actions during phase A" do
    repo = create_git_repo_fixture!(plan_content: "# done\n")
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)

    {:ok, pid} = SlotCoordinator.start_link(config: config, name: nil)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    assert {:error, {:slot_action_deferred, "checklist", "build"}} =
             SlotCoordinator.start_slot(pid,
               lane: "checklist",
               action: "build",
               runtime_surface: "service"
             )

    assert {:error, {:slot_action_deferred, "workflow", "run"}} =
             SlotCoordinator.start_slot(pid,
               lane: "workflow",
               action: "run",
               workflow_name: "alpha",
               runtime_surface: "service"
             )

    assert {:ok, owner_status} = ActiveRuntime.status(config)
    assert owner_status.live? == false
    assert RuntimeStateStore.read(config) in [:missing, {:error, :enoent}]
  end
end
