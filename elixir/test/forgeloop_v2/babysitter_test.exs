defmodule ForgeloopV2.BabysitterTest do
  use ForgeloopV2.TestSupport

  @shell_probe """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "PWD=$(pwd)"
  echo "REQUESTS=$FORGELOOP_REQUESTS_FILE"
  echo "PLAN=$FORGELOOP_IMPLEMENTATION_PLAN_FILE"
  echo "BRANCH=${FORGELOOP_RUNTIME_BRANCH:-}"
  """

  @shell_sleep """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "sleeping"
  sleep 30
  """

  test "shell babysitter run executes in the disposable worktree while keeping canonical artifact env paths" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_probe, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true)

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        heartbeat_interval_ms: 25,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid)
    wait_until(fn -> not Babysitter.snapshot(pid).running? end)

    output = File.read!(Path.join([config.v2_state_dir, "driver", "build-last.txt"]))
    prepared_event = Enum.find(Events.read_all(config), &(&1["event_type"] == "worktree_prepared"))
    checkout_path = prepared_event["checkout_path"]

    assert output =~ "PWD="
    assert output =~ Path.basename(checkout_path)
    assert output =~ "REQUESTS=#{config.requests_file}"
    assert output =~ "PLAN=#{config.plan_file}"
    assert output =~ "BRANCH=main"
    assert Enum.empty?(Path.wildcard(Path.join(PathPolicy.workspace_root(config), "*")))
  end

  test "forced stop pauses canonically and cleans the disposable worktree" do
    repo =
      create_git_repo_fixture!(
        loop_script_body: """
        #!/usr/bin/env bash
        set -euo pipefail
        sleep 1
        echo "late-write" >> "$FORGELOOP_REQUESTS_FILE"
        """
      )
    config = config_for!(repo.repo_root, shell_driver_enabled: true)

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        heartbeat_interval_ms: 25,
        shutdown_grace_ms: 50,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid)
    wait_until(fn -> Babysitter.snapshot(pid).running? and File.exists?(Worktree.active_run_path(config)) end)

    assert :ok = Babysitter.stop_child(pid, :kill)
    wait_until(fn -> not Babysitter.snapshot(pid).running? end)
    Process.sleep(1_100)
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    refute File.read!(config.requests_file) =~ "late-write"
    assert RuntimeStateStore.status(config) == "paused"
    assert Enum.empty?(Path.wildcard(Path.join(PathPolicy.workspace_root(config), "*")))

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert "babysitter_stopped" in event_types
  end

  test "rerun after clearing pause uses the existing recovery path" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep)
    config = config_for!(repo.repo_root, shell_driver_enabled: true)

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        heartbeat_interval_ms: 25,
        shutdown_grace_ms: 50,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid)
    wait_until(fn -> Babysitter.snapshot(pid).running? end)
    assert :ok = Babysitter.stop_child(pid, :pause)

    File.write!(config.requests_file, "")

    {:ok, pid2} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        driver: ForgeloopV2.WorkDrivers.Noop,
        heartbeat_interval_ms: 25,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid2)
    wait_until(fn -> not Babysitter.snapshot(pid2).running? end)

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])

    recovery_index =
      event_types
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {type, index} -> if type == "recovery_started", do: index end)

    loop_started_index =
      event_types
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {type, index} -> if type == "loop_started", do: index end)

    assert is_integer(recovery_index)
    assert is_integer(loop_started_index)
    assert recovery_index < loop_started_index
  end

  test "ui runtime surface is recorded separately from babysitter ownership metadata" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    config = config_for!(repo.repo_root, shell_driver_enabled: true, babysitter_shutdown_grace_ms: 50)

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        runtime_surface: "ui",
        driver: ForgeloopV2.WorkDrivers.ShellLoop,
        heartbeat_interval_ms: 25,
        shutdown_grace_ms: 50,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid)
    wait_until(fn -> Babysitter.snapshot(pid).running? and File.exists?(Worktree.active_run_path(config)) end)

    snapshot = Babysitter.snapshot(pid)
    active_run = Worktree.active_run_path(config) |> File.read!() |> Jason.decode!()

    assert snapshot.runtime_surface == "ui"
    assert active_run["runtime_surface"] == "ui"
    assert active_run["surface"] == "babysitter"

    assert :ok = Babysitter.stop_child(pid, :kill)
    wait_until(fn -> not Babysitter.snapshot(pid).running? end)
  end

  test "workflow stop records a bounded stopped outcome with the managed run id" do
    repo = create_git_repo_fixture!(plan_content: "# done\n")
    create_workflow_package!(repo.repo_root, "alpha")

    runner_path =
      write_executable!(Path.join(repo.repo_root, "bin/workflow-runner"), """
      #!/usr/bin/env bash
      set -euo pipefail
      sleep 30
      """)

    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow stop fixture"])

    config =
      config_for!(repo.repo_root,
        workflow_runner: runner_path,
        shell_driver_enabled: false,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, run_spec} = RunSpec.workflow(:run, "alpha")

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        run_spec: run_spec,
        runtime_surface: "ui",
        heartbeat_interval_ms: 25,
        shutdown_grace_ms: 50,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid, run_id: "wf-alpha-stop-1", started_at: "2026-03-21T00:00:00Z")
    wait_until(fn -> Babysitter.snapshot(pid).running? and File.exists?(Worktree.active_run_path(config)) end)

    active_run = Worktree.active_run_path(config) |> File.read!() |> Jason.decode!()
    assert active_run["run_id"] == "wf-alpha-stop-1"

    assert :ok = Babysitter.stop_child(pid, :pause)
    wait_until(fn -> not Babysitter.snapshot(pid).running? end)

    assert {:ok, history} = WorkflowHistory.fetch(config, "alpha")
    assert history.status == :available
    assert history.latest.run_id == "wf-alpha-stop-1"
    assert history.latest.outcome == :stopped
    assert history.latest.runtime_surface == "ui"
  end

  test "stale worktree cleanup runs before a fresh babysitter child starts" do
    repo = create_git_repo_fixture!()
    config = config_for!(repo.repo_root)
    {:ok, workspace} = Workspace.from_config(config, branch: "main", mode: "build", kind: "babysitter")
    {:ok, stale_handle} = Worktree.prepare(config, workspace)

    File.mkdir_p!(Path.dirname(Worktree.active_run_path(config)))

    File.write!(
      Worktree.active_run_path(config),
      Jason.encode!(%{"workspace_id" => workspace.workspace_id}, pretty: true) <> "\n"
    )

    {:ok, pid} =
      Babysitter.start_link(
        config: config,
        mode: :build,
        driver: ForgeloopV2.WorkDrivers.Noop,
        heartbeat_interval_ms: 25,
        name: nil
      )

    assert :ok = Babysitter.start_run(pid)
    wait_until(fn -> not Babysitter.snapshot(pid).running? end)

    refute File.exists?(stale_handle.checkout_path)
    refute File.exists?(stale_handle.metadata_file)
    assert Enum.empty?(Path.wildcard(Path.join(PathPolicy.workspace_root(config), "*")))
  end
end
