defmodule ForgeloopV2.ServiceTest do
  use ForgeloopV2.TestSupport

  @shell_sleep """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "sleeping"
  sleep 30
  """

  test "repo-root service serves static UI assets and overview includes provider health" do
    repo =
      create_repo_fixture!(
        plan_content: "- [ ] pending task\n",
        questions: """
        ## Q-1
        **Question**: Need input?
        **Status**: ⏳ Awaiting response
        """,
        escalations: """
        ## E-1
        - Kind: `spin`
        - Repeat count: `2`
        - Requested action: `review`
        - Summary: Investigate repeated failure
        """
      )

    layout = create_ui_layout!(repo.repo_root, :repo_root)
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    assert {:ok, _state} =
             RuntimeStateStore.write(config, %{
               status: "running",
               transition: "building",
               surface: "daemon",
               mode: "build",
               reason: "work in progress",
               requested_action: "",
               branch: "main"
             })

    :ok = ForgeloopV2.LLM.StateStore.write(config, %{"claude_auth_failed" => true})
    :ok = Events.emit(config, :provider_attempted, %{"provider" => "claude"})
    :ok = Events.emit(config, :daemon_tick, %{"action" => "build", "reason" => "pending task"})

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    html = get_response!(base_url <> "/")
    assert html.status == 200
    assert html.headers["content-type"] =~ "text/html"
    assert html.body =~ "hud"

    css = get_response!(base_url <> "/assets/app.css")
    assert css.status == 200
    assert css.headers["content-type"] =~ "text/css"

    js = get_response!(base_url <> "/assets/app.js")
    assert js.status == 200
    assert js.headers["content-type"] =~ "application/javascript"

    payload = get_json!(base_url <> "/api/overview")
    assert payload["ok"] == true
    assert payload["data"]["runtime_state"]["status"] == "running"
    assert payload["data"]["backlog"]["needs_build?"] == true
    assert payload["data"]["backlog"]["exists?"] == true
    assert payload["data"]["backlog"]["source"]["kind"] == "implementation_plan"
    assert payload["data"]["backlog"]["source"]["label"] == "IMPLEMENTATION_PLAN.md"
    assert payload["data"]["backlog"]["source"]["path"] == config.plan_file
    assert payload["data"]["backlog"]["source"]["canonical?"] == true
    assert payload["data"]["backlog"]["source"]["phase"] == "phase1"
    assert payload["data"]["control_flags"]["pause_requested?"] == false
    assert payload["data"]["control_flags"]["replan_requested?"] == false
    assert payload["data"]["control_flags"]["deploy_requested?"] == false
    assert payload["data"]["control_flags"]["ingest_logs_requested?"] == false
    assert payload["data"]["control_flags"]["workflow_requested?"] == false
    assert payload["data"]["control_flags"]["workflow_target"]["configured?"] == false
    assert payload["data"]["control_flags"]["workflow_target"]["valid?"] == false
    assert payload["data"]["control_flags"]["workflow_target"]["name"] == nil
    assert payload["data"]["control_flags"]["workflow_target"]["action"] == "preflight"
    assert payload["data"]["control_flags"]["workflow_target"]["error"] == nil
    assert payload["data"]["tracker"]["counts"]["total"] == 2
    assert payload["data"]["tracker"]["counts"]["backlog"] == 1
    assert payload["data"]["tracker"]["counts"]["workflows"] == 1
    assert Enum.any?(payload["data"]["tracker"]["issues"], &(&1["workflow_state"] == "plan_item"))
    assert Enum.any?(payload["data"]["tracker"]["issues"], &(&1["workflow_state"] == "workflow_pack"))
    assert Enum.at(payload["data"]["questions"], 0)["id"] == "Q-1"
    assert Enum.at(payload["data"]["escalations"], 0)["id"] == "E-1"
    assert Enum.any?(payload["data"]["events"], &(&1["event_type"] == "daemon_tick"))
    assert is_binary(payload["data"]["events_meta"]["latest_event_id"])
    assert payload["data"]["events_meta"]["returned_count"] >= 2
    assert Enum.at(payload["data"]["workflows"]["workflows"], 0)["entry"]["name"] == "alpha"
    assert payload["data"]["babysitter"]["running?"] == false
    assert Enum.any?(payload["data"]["provider_health"]["providers"], &(&1["name"] == "claude" and &1["status"] == "auth_failed"))

    providers = get_json!(base_url <> "/api/providers")
    assert providers["ok"] == true
    assert Enum.any?(providers["data"]["providers"], &(&1["name"] == "claude"))
  end

  test "vendored service startup resolves static assets from forgeloop/elixir" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root, :vendored)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    html = get_response!(base_url <> "/")
    assert html.status == 200
    assert html.body =~ "hud"
  end

  test "service backlog endpoint matches orchestrator pending-work answer for the same plan file" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ] Ship repo-local HUD
          - [ ] Keep nested follow-ups out of build detection
        """
      )

    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    orchestrator_context = Orchestrator.build_context(config)
    backlog_payload = get_json!(base_url <> "/api/backlog")

    assert backlog_payload["ok"] == true
    assert backlog_payload["data"]["needs_build?"] == orchestrator_context.needs_build?
    assert backlog_payload["data"]["exists?"] == true
    assert backlog_payload["data"]["source"]["kind"] == "implementation_plan"
    assert backlog_payload["data"]["source"]["label"] == "IMPLEMENTATION_PLAN.md"
    assert backlog_payload["data"]["source"]["canonical?"] == true
    assert backlog_payload["data"]["source"]["phase"] == "phase1"
    assert length(backlog_payload["data"]["items"]) == 2
  end

  test "service overview exposes daemon workflow request visibility" do
    repo = create_repo_fixture!(plan_content: "# done\n", requests: "[WORKFLOW]\n")
    layout = create_ui_layout!(repo.repo_root)

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        daemon_workflow_name: "alpha",
        daemon_workflow_action: "run"
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    payload = get_json!(base_url <> "/api/overview")

    assert payload["ok"] == true
    assert payload["data"]["control_flags"]["workflow_requested?"] == true
    assert payload["data"]["control_flags"]["workflow_target"]["configured?"] == true
    assert payload["data"]["control_flags"]["workflow_target"]["valid?"] == true
    assert payload["data"]["control_flags"]["workflow_target"]["name"] == "alpha"
    assert payload["data"]["control_flags"]["workflow_target"]["action"] == "run"
    assert payload["data"]["control_flags"]["workflow_target"]["mode"] == "workflow-run"
    assert payload["data"]["control_flags"]["workflow_target"]["error"] == nil
  end

  test "service overview marks invalid daemon workflow requests explicitly" do
    repo = create_repo_fixture!(plan_content: "# done\n", requests: "[WORKFLOW]\n")
    layout = create_ui_layout!(repo.repo_root)

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        daemon_workflow_name: "alpha",
        daemon_workflow_action: "launch"
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    payload = get_json!(base_url <> "/api/overview")

    assert payload["ok"] == true
    assert payload["data"]["control_flags"]["workflow_requested?"] == true
    assert payload["data"]["control_flags"]["workflow_target"]["configured?"] == true
    assert payload["data"]["control_flags"]["workflow_target"]["valid?"] == false
    assert payload["data"]["control_flags"]["workflow_target"]["name"] == "alpha"
    assert payload["data"]["control_flags"]["workflow_target"]["action"] == "launch"
    assert payload["data"]["control_flags"]["workflow_target"]["mode"] == nil
    assert payload["data"]["control_flags"]["workflow_target"]["error"] == "invalid_daemon_workflow_action"
  end

  test "service tracker endpoint exposes repo-local projected issues" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ] Ship tracker seam
          - [ ] Keep it read-only
        """
      )

    create_workflow_package!(repo.repo_root, "alpha")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    tracker_payload = get_json!(base_url <> "/api/tracker")

    assert tracker_payload["ok"] == true
    assert tracker_payload["data"]["counts"]["total"] == 2
    assert tracker_payload["data"]["sources"]["backlog"]["kind"] == "implementation_plan"
    assert tracker_payload["data"]["sources"]["workflows"]["kind"] == "workflow_catalog"
    assert Enum.any?(tracker_payload["data"]["issues"], &(&1["id"] == "plan:2" and &1["workflow_state"] == "plan_item"))
    assert Enum.any?(tracker_payload["data"]["issues"], &(&1["id"] == "workflow:alpha" and &1["workflow_state"] == "workflow_pack"))
  end

  test "service backlog stays fail-closed when the configured plan path is unreadable" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0, plan_file: ".")
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    backlog_payload = get_json!(base_url <> "/api/backlog")
    tracker_payload = get_json!(base_url <> "/api/tracker")

    assert backlog_payload["ok"] == true
    assert backlog_payload["data"]["needs_build?"] == true
    assert backlog_payload["data"]["exists?"] == true
    assert backlog_payload["data"]["items"] == []
    assert backlog_payload["data"]["source"]["path"] == repo.repo_root
    assert tracker_payload["ok"] == true
    assert tracker_payload["data"]["counts"]["blocked"] == 1
    assert Enum.any?(tracker_payload["data"]["issues"], &(&1["id"] == "plan:alert" and &1["workflow_state"] == "backlog_alert"))
  end

  test "pause, replan, question answer, and resolve endpoints mutate canonical files safely" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: Need input?
        **Status**: ⏳ Awaiting response
        """
      )

    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    question = get_json!(base_url <> "/api/questions")["data"] |> Enum.at(0)
    assert post_json!(base_url <> "/api/control/pause", %{})["ok"] == true
    assert post_json!(base_url <> "/api/control/replan", %{})["ok"] == true

    answer_payload =
      post_json!(base_url <> "/api/questions/Q-1/answer", %{
        "answer" => "Proceed.",
        "expected_revision" => question["revision"]
      })

    assert answer_payload["ok"] == true
    assert answer_payload["data"]["question"]["status_kind"] == "answered"

    resolve_payload =
      post_json!(base_url <> "/api/questions/Q-1/resolve", %{
        "answer" => "Proceed.",
        "expected_revision" => answer_payload["data"]["question"]["revision"]
      })

    assert resolve_payload["ok"] == true
    assert resolve_payload["data"]["question"]["status_kind"] == "resolved"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.requests_file) =~ "[REPLAN]"
    assert File.read!(config.questions_file) =~ "Proceed."

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "paused"
    assert state.surface == "service"
  end

  test "clear pause endpoint is idempotent and recovery stays daemon-driven" do
    repo = create_repo_fixture!(requests: "[PAUSE]\n", plan_content: "# done\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    assert {:ok, _state} =
             RuntimeStateStore.write(config, %{
               status: "paused",
               transition: "paused",
               surface: "daemon",
               mode: "daemon",
               reason: "Paused via operator",
               requested_action: "",
               branch: "main"
             })

    {:ok, service_pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(service_pid, :shutdown) end)

    clear_payload = post_json!(base_url <> "/api/control/clear-pause", %{})
    assert clear_payload["ok"] == true
    assert clear_payload["data"]["cleared?"] == true
    refute File.read!(config.requests_file) =~ "[PAUSE]"

    assert {:ok, paused_state} = RuntimeStateStore.read(config)
    assert paused_state.status == "paused"

    second_payload = post_json!(base_url <> "/api/control/clear-pause", %{})
    assert second_payload["ok"] == true
    assert second_payload["data"]["cleared?"] == false

    {:ok, daemon_pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)
    Daemon.run_once(daemon_pid)
    wait_until(fn -> not Daemon.snapshot(daemon_pid).running? end)

    assert {:ok, recovered_state} = RuntimeStateStore.read(config)
    assert recovered_state.status == "recovered"

    Daemon.run_once(daemon_pid)
    wait_until(fn -> not Daemon.snapshot(daemon_pid).running? end)

    assert {:ok, final_state} = RuntimeStateStore.read(config)
    assert final_state.status == "idle"
  end

  test "answering a question through the service changes the next recovery decision" do
    repo =
      create_repo_fixture!(
        plan_content: "# done\n",
        questions: """
        ## Q-1
        **Question**: Need input?
        **Status**: ⏳ Awaiting response
        """
      )

    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, _} =
      RuntimeLifecycle.transition(config, :human_escalated, :escalation, %{
        surface: "loop",
        mode: "build",
        reason: "Need operator input",
        requested_action: "issue",
        branch: "main"
      })

    :ok = ControlFiles.consume_flag(config, "PAUSE")

    {:ok, service_pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(service_pid, :shutdown) end)

    {:ok, daemon_pid} = Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)
    Daemon.run_once(daemon_pid)
    wait_until(fn -> not Daemon.snapshot(daemon_pid).running? end)
    assert RuntimeStateStore.status(config) == "awaiting-human"

    question = get_json!(base_url <> "/api/questions")["data"] |> Enum.at(0)

    answer_payload =
      post_json!(base_url <> "/api/questions/Q-1/answer", %{
        "answer" => "Approved.",
        "expected_revision" => question["revision"]
      })

    assert answer_payload["ok"] == true

    Daemon.run_once(daemon_pid)
    wait_until(fn -> not Daemon.snapshot(daemon_pid).running? end)

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "recovered"
  end

  test "babysitter endpoints serialize manual runs and allow stop through the loopback service" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/babysitter/start", %{"mode" => "build"})
    assert start_payload["ok"] == true
    assert start_payload["data"]["mode"] == "build"

    conflict = post_json_response!(base_url <> "/api/babysitter/start", %{"mode" => "build"})
    assert conflict.status == 409
    assert conflict.body["error"]["reason"] == "babysitter_already_running"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    stop_payload = post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})
    assert stop_payload["ok"] == true

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert RuntimeStateStore.status(config) == "paused"
  end

  test "ui control runs use the ui surface and reject concurrent starts" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/control/run", %{"mode" => "build"})
    assert start_payload["ok"] == true
    assert start_payload["data"]["surface"] == "ui"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    babysitter_payload = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter_payload["runtime_surface"] == "ui"
    assert babysitter_payload["active_run"]["runtime_surface"] == "ui"
    assert babysitter_payload["active_run"]["surface"] == "babysitter"

    conflict = post_json_response!(base_url <> "/api/control/run", %{"mode" => "build"})
    assert conflict.status == 409
    assert conflict.body["error"]["reason"] == "babysitter_already_running"

    stop_payload = post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})
    assert stop_payload["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
  end

  test "idle managed babysitters are replaced when mode or runtime surface changes" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    assert post_json!(base_url <> "/api/control/run", %{"mode" => "build"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)
    assert post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)

    second_start = post_json!(base_url <> "/api/babysitter/start", %{"mode" => "plan"})
    assert second_start["ok"] == true
    assert second_start["data"]["surface"] == "babysitter"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    babysitter_payload = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter_payload["mode"] == "plan"
    assert babysitter_payload["runtime_surface"] == "babysitter"
    assert babysitter_payload["active_run"]["mode"] == "plan"
    assert babysitter_payload["active_run"]["runtime_surface"] == "babysitter"

    assert post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
  end

  test "workflow endpoints launch managed workflow runs and expose live workflow status" do
    repo =
      create_git_repo_fixture!(
        plan_content: "- [ ] build\n",
        loop_script_body: "#!/usr/bin/env bash\nset -euo pipefail\necho noop\n"
      )
    create_workflow_package!(repo.repo_root, "alpha")
    layout = create_ui_layout!(repo.repo_root)

    runner =
      write_executable!(
        Path.join(repo.repo_root, "bin/fake-workflow-runner.sh"),
        """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ \"${1:-}\" != \"run\" ]]; then
          echo \"unexpected:$*\" >&2
          exit 2
        fi
        shift
        mode=run
        if [[ \"${1:-}\" == \"--preflight\" ]]; then
          mode=preflight
          shift
        fi
        workflow=\"${1:-}\"
        echo \"ok:${mode}:${workflow}\"
        sleep 1
        """
      )

    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: false,
        workflow_runner: runner,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/workflows/alpha/preflight", %{})
    assert start_payload["ok"] == true
    assert start_payload["data"]["lane"] == "workflow"
    assert start_payload["data"]["action"] == "preflight"
    assert start_payload["data"]["workflow"] == "alpha"
    assert start_payload["data"]["surface"] == "ui"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    babysitter_payload = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter_payload["lane"] == "workflow"
    assert babysitter_payload["action"] == "preflight"
    assert babysitter_payload["mode"] == "workflow-preflight"
    assert babysitter_payload["workflow_name"] == "alpha"
    assert babysitter_payload["runtime_surface"] == "ui"

    workflow_payload = get_json!(base_url <> "/api/workflows/alpha")["data"]
    assert workflow_payload["active_run"]["workflow_name"] == "alpha"
    assert workflow_payload["active_run"]["action"] == "preflight"
    assert workflow_payload["active_run"]["runtime_surface"] == "ui"
    assert is_binary(workflow_payload["active_run"]["run_id"])

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end, 4_000)
    assert File.read!(Path.join([config.runtime_dir, "workflows", "alpha", "last-preflight.txt"])) =~ "ok:preflight:alpha"

    completed_payload = get_json!(base_url <> "/api/workflows/alpha")["data"]
    assert completed_payload["history"]["status"] == "available"
    assert completed_payload["history"]["latest"]["outcome"] == "succeeded"
    assert completed_payload["history"]["latest"]["action"] == "preflight"
    assert Enum.count(completed_payload["history"]["entries"]) >= 1
  end

  test "workflow endpoints return stable workflow-specific error codes" do
    repo = create_git_repo_fixture!(plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: false,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    invalid_runner_args = post_json_response!(base_url <> "/api/workflows/alpha/run", %{"runner_args" => [1]})
    assert invalid_runner_args.status == 400
    assert invalid_runner_args.body["error"]["reason"] == "invalid_runner_args"

    missing = post_json_response!(base_url <> "/api/workflows/missing/run", %{})
    assert missing.status == 404
    assert missing.body["error"]["reason"] == "workflow_not_found"
  end

  test "manual control runs accept the openclaw runtime surface" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/control/run", %{"mode" => "build", "surface" => "openclaw"})
    assert start_payload["ok"] == true
    assert start_payload["data"]["surface"] == "openclaw"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    babysitter_payload = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter_payload["runtime_surface"] == "openclaw"
    assert babysitter_payload["active_run"]["runtime_surface"] == "openclaw"
    assert babysitter_payload["active_run"]["surface"] == "babysitter"

    assert post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
  end

  test "ui-triggered failing builds still escalate through canonical artifacts" do
    repo =
      create_git_repo_fixture!(
        loop_script_body: """
        #!/usr/bin/env bash
        set -euo pipefail
        echo "boom"
        exit 1
        """,
        plan_content: "- [ ] build\n"
      )

    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        failure_escalate_after: 1,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/control/run", %{"mode" => "build"})
    assert start_payload["ok"] == true
    assert start_payload["data"]["surface"] == "ui"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end, 4_000)

    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.questions_file) =~ "## Q-"
    assert File.read!(config.escalations_file) =~ "## E-"

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert state.surface == "ui"
  end

  test "events endpoint exposes bounded tail and replay metadata" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok = Events.emit(config, :daemon_tick, %{"action" => "first", "recorded_at" => "2026-03-21T10:00:00Z"})
    :ok = Events.emit(config, :operator_action, %{"action" => "second", "recorded_at" => "2026-03-21T10:01:00Z"})
    :ok = Events.emit(config, :operator_action, %{"action" => "third", "recorded_at" => "2026-03-21T10:02:00Z"})

    tail_payload = get_json!(base_url <> "/api/events?limit=2")
    assert tail_payload["ok"] == true
    assert Enum.map(tail_payload["data"], & &1["action"]) == ["second", "third"]
    assert tail_payload["meta"]["returned_count"] == 2
    assert tail_payload["meta"]["truncated?"] == true

    replay_cursor = Enum.at(tail_payload["data"], 0)["event_id"]
    replay_payload = get_json!(base_url <> "/api/events?after=#{URI.encode_www_form(replay_cursor)}&limit=5")
    assert replay_payload["ok"] == true
    assert replay_payload["meta"]["cursor_found?"] == true
    assert Enum.map(replay_payload["data"], & &1["action"]) == ["third"]

    missing_payload = get_json!(base_url <> "/api/events?after=evt-missing&limit=5")
    assert missing_payload["ok"] == true
    assert missing_payload["meta"]["cursor_found?"] == false
    assert missing_payload["data"] == []
  end

  test "stream endpoint emits a bootstrap snapshot and then live event frames" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    {:ok, socket} = open_stream_socket(base_url <> "/api/stream?limit=5")
    on_exit(fn -> :gen_tcp.close(socket) end)

    first = recv_until(socket, "event: snapshot", 4_000)
    assert first =~ "event: snapshot"
    assert first =~ "pending task"

    :ok = Events.emit(config, :operator_action, %{"action" => "stream_probe", "recorded_at" => "2026-03-21T10:03:00Z"})

    second = recv_until(socket, "stream_probe", 4_000)
    assert second =~ "event: event"
    assert second =~ "id: evt-"
    assert second =~ "stream_probe"
  end

  test "stream endpoint replays missed events when a cursor is supplied" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok = Events.emit(config, :operator_action, %{"action" => "resume_probe_one", "recorded_at" => "2026-03-21T10:04:00Z"})
    :ok = Events.emit(config, :operator_action, %{"action" => "resume_probe_two", "recorded_at" => "2026-03-21T10:05:00Z"})

    events_payload = get_json!(base_url <> "/api/events?limit=5")
    after_cursor = Enum.find(events_payload["data"], &(&1["action"] == "resume_probe_one"))["event_id"]

    {:ok, socket} = open_stream_socket(base_url <> "/api/stream?limit=5&after=#{URI.encode_www_form(after_cursor)}")
    on_exit(fn -> :gen_tcp.close(socket) end)

    replay = recv_until(socket, "resume_probe_two", 4_000)
    refute replay =~ "event: snapshot"
    assert replay =~ "event: event"
    assert replay =~ "resume_probe_two"
  end

  defp start_service!(config) do
    {:ok, pid} = Service.start_link(config: config, port: config.service_port, host: config.service_host, name: nil, control_plane_name: nil)
    %{base_url: base_url} = Service.snapshot(pid)
    {:ok, pid, base_url}
  end

  defp get_json!(url) do
    response = get_response!(url)
    assert response.status == 200
    assert is_map(response.body)
    response.body
  end

  defp get_response!(url) do
    response = request!(:get, url, nil)
    assert response.status == 200
    response
  end

  defp post_json!(url, payload) do
    response = post_json_response!(url, payload)
    assert response.status == 200
    response.body
  end

  defp post_json_response!(url, payload) do
    request!(:post, url, Jason.encode!(payload))
  end

  defp request!(:get, url, _body) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "GET ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "connection: close\r\n\r\n"
        ]
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    decode_response(response)
  end

  defp request!(:post, url, body) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "POST ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "content-type: application/json\r\n",
          "content-length: ", Integer.to_string(byte_size(body)), "\r\n",
          "connection: close\r\n\r\n",
          body
        ]
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    decode_response(response)
  end

  defp open_stream_socket(url) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "GET ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "accept: text/event-stream\r\n",
          "connection: keep-alive\r\n\r\n"
        ]
      )

    {:ok, socket}
  end

  defp recv_until(socket, needle, timeout_ms, acc \\ "") do
    if String.contains?(acc, needle) do
      acc
    else
      case :gen_tcp.recv(socket, 0, timeout_ms) do
        {:ok, chunk} -> recv_until(socket, needle, timeout_ms, acc <> chunk)
        {:error, reason} -> raise "stream closed before #{inspect(needle)}: #{inspect(reason)}\n#{acc}"
      end
    end
  end

  defp recv_all(socket, acc, retries \\ 3) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk, 3)
      {:error, :closed} -> acc
      {:error, :timeout} when acc != "" -> acc
      {:error, :timeout} when retries > 0 -> recv_all(socket, acc, retries - 1)
      {:error, reason} -> raise "socket read failed: #{inspect(reason)}\n#{acc}"
    end
  end

  defp decode_response(response) do
    [status_line, rest] = String.split(response, "\r\n", parts: 2)
    [_, status, _reason] = String.split(status_line, " ", parts: 3)
    [headers_blob, body] = String.split(rest, "\r\n\r\n", parts: 2)
    headers = parse_headers(headers_blob)

    %{
      status: String.to_integer(status),
      headers: headers,
      body: decode_body(headers, body)
    }
  end

  defp parse_headers(headers_blob) do
    headers_blob
    |> String.split("\r\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp decode_body(headers, body) do
    if String.contains?(Map.get(headers, "content-type", ""), "application/json") do
      Jason.decode!(body)
    else
      body
    end
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query
end
