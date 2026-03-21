defmodule ForgeloopV2.EventsTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.LLM.Router

  test "failure, pause, recovery, blocker, and failover flows emit events" do
    repo =
      create_repo_fixture!(
        plan_content: """
        - [ ] pending task
        """,
        questions: """
        ## Q-1 (2026-03-05 00:00:00)
        **Category**: blocked
        **Question**: Human input required
        **Status**: ⏳ Awaiting response

        **Answer**:
        """
      )

    config = config_for!(repo.repo_root, failure_escalate_after: 2, max_blocked_iterations: 2)
    evidence_file = Path.join(repo.repo_root, "evidence.txt")
    File.write!(evidence_file, "CI failed badly\n")

    assert {:ok, _} =
             RuntimeLifecycle.transition(config, :paused_by_operator, :daemon, %{
               surface: "daemon",
               mode: "daemon",
               reason: "Pause requested via REQUESTS.md",
               branch: "main"
             })

    assert {:retry, 1} =
             FailureTracker.handle(config, %{
               kind: "ci",
               summary: "CI failed",
               evidence_file: evidence_file,
               requested_action: "issue",
               surface: "loop",
               mode: "build",
               branch: "main"
             })

    assert {:stop, 2} =
             FailureTracker.handle(config, %{
               kind: "ci",
               summary: "CI failed",
               evidence_file: evidence_file,
               requested_action: "issue",
               surface: "loop",
               mode: "build",
               branch: "main"
             })

    File.write!(config.requests_file, "[PAUSE]\n")
    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)
    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    File.write!(config.requests_file, "")
    assert {:threshold_reached, _} = BlockerDetector.check(config)
    assert {:threshold_reached, _} = BlockerDetector.check(config)
    File.write!(config.questions_file, "")
    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    fake_bin = Path.join(repo.repo_root, ".fake-bin")

    write_executable!(
      Path.join(fake_bin, "claude"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "Invalid API Key"
      exit 0
      """
    )

    write_executable!(
      Path.join(fake_bin, "codex"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "codex-fallback-ok"
      exit 0
      """
    )

    with_env([{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}], fn ->
      assert {:ok, _result} = Router.exec(:build, "hello\n", config)
    end)

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])

    assert "failure_recorded" in event_types
    assert "failure_escalated" in event_types
    assert "blocker_tracking" in event_types
    assert "blocker_escalated" in event_types
    assert "pause_detected" in event_types
    assert "recovery_started" in event_types
    assert "provider_attempted" in event_types
    assert "provider_failed_over" in event_types
  end

  test "daemon checklist runs emit babysitter and worktree events" do
    repo =
      create_git_repo_fixture!(
        loop_script_body: """
        #!/usr/bin/env bash
        set -euo pipefail
        echo "daemon-managed"
        """,
        plan_content: "- [ ] build\n"
      )

    config = config_for!(repo.repo_root, shell_driver_enabled: true)
    {:ok, pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.ShellLoop, schedule: false)

    Daemon.run_once(pid)
    wait_until(fn -> not Daemon.snapshot(pid).running? end)

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])

    assert "worktree_prepared" in event_types
    assert "babysitter_started" in event_types
    assert "loop_started" in event_types
    assert "loop_completed" in event_types
    assert "babysitter_completed" in event_types
    assert "worktree_cleaned" in event_types
  end
end
