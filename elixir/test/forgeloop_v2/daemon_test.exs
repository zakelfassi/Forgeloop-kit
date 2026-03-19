defmodule ForgeloopV2.DaemonTest do
  use ForgeloopV2.TestSupport

  test "blocker escalation reuses the tick blocker snapshot" do
    repo =
      create_repo_fixture!(
        plan_content: "# done\n",
        questions: """
        ## Q-123 (2026-03-05 00:00:00)
        **Category**: blocked
        **Question**: Human input required
        **Status**: ⏳ Awaiting response

        **Answer**:
        """
      )

    config = config_for!(repo.repo_root, max_blocked_iterations: 1)
    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert Daemon.snapshot(pid).last_action == :blocker_escalated

    assert File.read!(config.escalations_file) =~ "1 consecutive cycles"

    daemon_state =
      config.v2_state_dir
      |> Path.join("daemon-state.json")
      |> File.read!()
      |> Jason.decode!()

    assert daemon_state["blocked_iteration_count"] == 1

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert Enum.count(event_types, &(&1 == "blocker_escalated")) == 1
  end

  test "pause flag writes paused runtime state" do
    repo = create_repo_fixture!(requests: "[PAUSE]\n")
    config = config_for!(repo.repo_root)
    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "paused"
  end

  test "clearing pause writes recovered then returns to idle with no pending work" do
    repo = create_repo_fixture!(plan_content: "# done\n")
    config = config_for!(repo.repo_root)

    {:ok, _} =
      RuntimeStateStore.write(config, %{
        status: "paused",
        transition: "paused",
        surface: "daemon",
        mode: "daemon",
        reason: "Paused",
        requested_action: "",
        branch: "main"
      })

    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)
    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, recovered} = RuntimeStateStore.read(config)
    assert recovered.status == "recovered"

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "idle"
    assert state.previous_status == "recovered"
  end

  test "awaiting-human state does not auto-recover while unanswered questions remain" do
    repo =
      create_repo_fixture!(
        plan_content: "# done\n",
        questions: """
        ## Q-123 (2026-03-05 00:00:00)
        **Category**: blocked
        **Question**: Human input required
        **Status**: ⏳ Awaiting response

        **Answer**:
        """
      )

    config = config_for!(repo.repo_root)

    {:ok, _} =
      RuntimeLifecycle.transition(config, :human_escalated, :escalation, %{
        surface: "loop",
        mode: "build",
        reason: "Need operator input",
        requested_action: "issue",
        branch: "main"
      })

    ControlFiles.consume_flag(config, "PAUSE")

    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)
    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert Daemon.snapshot(pid).last_action == :idle
  end

  test "replan flag chooses plan and missing plan chooses build" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    File.write!(config.requests_file, "[REPLAN]\n")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.Noop,
        driver_opts: [plan: {:ok, %{mode: :plan}}, build: {:ok, %{mode: :build}}],
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)
    assert Daemon.snapshot(pid).last_action == :plan

    File.rm(config.plan_file)
    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)
    assert Daemon.snapshot(pid).last_action == :build
  end
end
