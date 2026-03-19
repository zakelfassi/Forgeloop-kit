defmodule ForgeloopV2.DaemonTest do
  use ForgeloopV2.TestSupport

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

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "idle"
    assert state.previous_status == "recovered"
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
