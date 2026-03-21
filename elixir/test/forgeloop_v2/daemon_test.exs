defmodule ForgeloopV2.DaemonTest do
  use ForgeloopV2.TestSupport

  @shell_probe """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "PWD=$(pwd)"
  echo "REQUESTS=$FORGELOOP_REQUESTS_FILE"
  echo "PLAN=$FORGELOOP_IMPLEMENTATION_PLAN_FILE"
  echo "SURFACE=${FORGELOOP_RUNTIME_SURFACE:-}"
  echo "MODE=${FORGELOOP_RUNTIME_MODE:-}"
  """

  @shell_sleep """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "sleeping"
  sleep 30
  """

  @workflow_runner """
  #!/usr/bin/env bash
  set -euo pipefail
  if [[ "${1:-}" != "run" ]]; then
    echo "unexpected:$*" >&2
    exit 2
  fi
  shift
  mode=run
  if [[ "${1:-}" == "--preflight" ]]; then
    mode=preflight
    shift
  fi
  workflow="${1:-}"
  echo "ok:${mode}:${workflow}"
  echo "surface=${FORGELOOP_RUNTIME_SURFACE:-}"
  echo "runtime_mode=${FORGELOOP_RUNTIME_MODE:-}"
  echo "workflow=${FORGELOOP_WORKFLOW_NAME:-}"
  """

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
    repo = create_git_repo_fixture!()
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

  test "daemon plan runs in a disposable worktree and consumes replan only after managed start" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_probe, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true)
    File.write!(config.requests_file, "[REPLAN]\n")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    output = File.read!(Path.join([config.v2_state_dir, "driver", "plan-last.txt"]))
    prepared_event = Enum.find(Events.read_all(config), &(&1["event_type"] == "worktree_prepared"))
    checkout_path = prepared_event["checkout_path"]

    assert output =~ "PWD="
    assert output =~ Path.basename(checkout_path)
    assert output =~ "REQUESTS=#{config.requests_file}"
    assert output =~ "PLAN=#{config.plan_file}"
    assert output =~ "SURFACE=daemon"
    assert output =~ "MODE=plan"
    assert File.read!(config.requests_file) == ""
    assert Enum.empty?(Path.wildcard(Path.join(PathPolicy.workspace_root(config), "*")))

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.surface == "daemon"

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert "worktree_prepared" in event_types
    assert "babysitter_started" in event_types
    assert "babysitter_completed" in event_types
    assert "worktree_cleaned" in event_types
  end

  test "daemon can schedule one configured workflow request through the managed worktree path" do
    repo = create_git_repo_fixture!(plan_content: "# done\n")
    create_workflow_package!(repo.repo_root, "alpha")

    runner =
      write_executable!(Path.join(repo.repo_root, "bin/fake-workflow-runner.sh"), @workflow_runner)

    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow fixture"])

    config =
      config_for!(repo.repo_root,
        daemon_workflow_name: "alpha",
        daemon_workflow_action: "preflight",
        workflow_runner: runner
      )

    File.write!(config.requests_file, "[WORKFLOW]\n")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end, 4_000)

    assert Daemon.snapshot(pid).last_action == {:workflow, :preflight, "alpha"}
    assert File.read!(config.requests_file) == ""

    artifact = Path.join([config.runtime_dir, "workflows", "alpha", "last-preflight.txt"])
    assert File.read!(artifact) =~ "ok:preflight:alpha"
    assert File.read!(artifact) =~ "surface=daemon"
    assert File.read!(artifact) =~ "runtime_mode=workflow-preflight"
    assert File.read!(artifact) =~ "workflow=alpha"
    assert Enum.empty?(Path.wildcard(Path.join(PathPolicy.workspace_root(config), "*")))

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.surface == "daemon"
    assert state.mode == "workflow-preflight"
  end

  test "daemon does not tear down an already-running managed babysitter" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true, babysitter_shutdown_grace_ms: 50)

    {:ok, babysitter_pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        runtime_surface: "ui",
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        heartbeat_interval_ms: 25,
        shutdown_grace_ms: 50,
        name: nil
      )

    assert :ok = Babysitter.start_run(babysitter_pid)
    wait_until(fn -> Babysitter.snapshot(babysitter_pid).running? and File.exists?(Worktree.active_run_path(config)) end)
    active_run_before = Worktree.active_run_path(config) |> File.read!() |> Jason.decode!()

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.Noop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert Babysitter.snapshot(babysitter_pid).running?
    active_run_after = Worktree.active_run_path(config) |> File.read!() |> Jason.decode!()
    assert active_run_after["workspace_id"] == active_run_before["workspace_id"]
    assert match?({:stopped, {:managed_run_active, _}}, Daemon.snapshot(pid).last_result)

    assert :ok = Babysitter.stop_child(babysitter_pid, :kill)
    wait_until(fn -> not Babysitter.snapshot(babysitter_pid).running? end)
  end

  test "managed daemon start failure escalates fail-closed and preserves replan" do
    repo = create_git_repo_fixture!(plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, failure_escalate_after: 1)
    File.write!(config.requests_file, "[REPLAN]\n")
    File.write!(Path.join(repo.repo_root, "dirty.txt"), "uncommitted\n")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.Noop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.requests_file) =~ "[REPLAN]"
    assert File.exists?(Path.join([config.v2_state_dir, "babysitter", "daemon-plan-start-error-last.txt"]))

    last_result = Daemon.snapshot(pid).last_result
    assert match?({:stopped, {:escalated, 1}}, last_result)
  end

  test "managed daemon workflow start failure preserves workflow request until a run really starts" do
    repo = create_git_repo_fixture!(plan_content: "# done\n")
    create_workflow_package!(repo.repo_root, "alpha")

    runner =
      write_executable!(Path.join(repo.repo_root, "bin/fake-workflow-runner.sh"), @workflow_runner)

    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow fixture"])

    config =
      config_for!(repo.repo_root,
        daemon_workflow_name: "alpha",
        daemon_workflow_action: "preflight",
        workflow_runner: runner,
        failure_escalate_after: 1
      )

    File.write!(config.requests_file, "[WORKFLOW]\n")
    File.write!(Path.join(repo.repo_root, "dirty.txt"), "uncommitted\n")

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.requests_file) =~ "[WORKFLOW]"

    assert [_evidence_file] =
             Path.wildcard(Path.join([config.v2_state_dir, "babysitter", "daemon-workflow-*-start-error-last.txt"]))

    assert match?({:stopped, {:escalated, 1}}, Daemon.snapshot(pid).last_result)
  end

  test "invalid daemon workflow config fails closed without consuming the request marker" do
    repo = create_git_repo_fixture!(plan_content: "# done\n", requests: "[WORKFLOW]\n")

    config =
      config_for!(repo.repo_root,
        daemon_workflow_name: "alpha",
        daemon_workflow_action: "launch",
        failure_escalate_after: 1
      )

    {:ok, pid} =
      Daemon.start_link(
        config: config,
        driver: ForgeloopV2.WorkDrivers.Noop,
        schedule: false
      )

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.requests_file) =~ "[WORKFLOW]"

    assert [_evidence_file] =
             Path.wildcard(Path.join([config.v2_state_dir, "babysitter", "daemon-workflow-*-start-error-last.txt"]))

    assert match?({:stopped, {:escalated, 1}}, Daemon.snapshot(pid).last_result)
    assert Daemon.snapshot(pid).last_action == :workflow_error
  end
end
