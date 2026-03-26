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
    assert payload["api"]["name"] == "forgeloop_loopback"
    assert payload["api"]["contract_version"] == 1
    assert payload["api"]["schema_path"] == "/api/schema"
    assert payload["data"]["runtime_state"]["status"] == "running"
    assert payload["data"]["runtime_owner"]["current"] == nil
    assert payload["data"]["runtime_owner"]["live?"] == false
    assert payload["data"]["runtime_owner"]["start_allowed?"] == true
    assert payload["data"]["ownership"]["summary_state"] == "ready"
    assert payload["data"]["ownership"]["start_allowed?"] == true
    assert payload["data"]["ownership"]["start_gate"]["status"] == "allowed"
    assert payload["data"]["ownership"]["runtime_owner"]["state"] == "missing"
    assert payload["data"]["ownership"]["active_run"]["state"] == "missing"
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

    assert Enum.any?(
             payload["data"]["tracker"]["issues"],
             &(&1["workflow_state"] == "workflow_pack")
           )

    assert Enum.at(payload["data"]["questions"], 0)["id"] == "Q-1"
    assert Enum.at(payload["data"]["escalations"], 0)["id"] == "E-1"
    assert Enum.any?(payload["data"]["events"], &(&1["event_type"] == "daemon_tick"))
    assert is_binary(payload["data"]["events_meta"]["latest_event_id"])
    assert payload["data"]["events_meta"]["returned_count"] >= 2
    assert Enum.at(payload["data"]["workflows"]["workflows"], 0)["entry"]["name"] == "alpha"
    assert payload["data"]["babysitter"]["running?"] == false

    assert Enum.any?(
             payload["data"]["provider_health"]["providers"],
             &(&1["name"] == "claude" and &1["status"] == "auth_failed")
           )

    providers = get_json!(base_url <> "/api/providers")
    assert providers["ok"] == true
    assert providers["api"]["contract_version"] == 1
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

  test "service schema endpoint describes the versioned loopback contract" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    payload = get_json!(base_url <> "/api/schema")
    assert payload["ok"] == true
    assert payload["api"]["contract_version"] == 1
    assert payload["data"]["contract_name"] == "forgeloop_loopback"
    assert payload["data"]["contract_version"] == 1
    assert payload["data"]["payload_versions"]["coordination"] == 1
    assert payload["data"]["payload_versions"]["ownership"] == 1
    assert payload["data"]["payload_versions"]["slots"] == 1
    assert payload["data"]["endpoints"]["overview"]["path"] == "/api/overview"
    assert payload["data"]["endpoints"]["stream"]["path"] == "/api/stream"
    assert payload["data"]["endpoints"]["questions"]["answer_path_template"] == "/api/questions/{question_id}/answer"
    assert payload["data"]["endpoints"]["slots"]["path"] == "/api/slots"
    assert payload["data"]["endpoints"]["slots"]["fetch_path_template"] == "/api/slots/{slot_id}"
    assert payload["data"]["endpoints"]["slots"]["stop_path_template"] == "/api/slots/{slot_id}/stop"
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

    assert payload["data"]["control_flags"]["workflow_target"]["error"] ==
             "invalid_daemon_workflow_action"
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

    assert Enum.any?(
             tracker_payload["data"]["issues"],
             &(&1["id"] == "plan:2" and &1["workflow_state"] == "plan_item")
           )

    assert Enum.any?(
             tracker_payload["data"]["issues"],
             &(&1["id"] == "workflow:alpha" and &1["workflow_state"] == "workflow_pack")
           )
  end

  test "service backlog stays fail-closed when the configured plan path is unreadable" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root)

    config =
      config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0, plan_file: ".")

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

    assert Enum.any?(
             tracker_payload["data"]["issues"],
             &(&1["id"] == "plan:alert" and &1["workflow_state"] == "backlog_alert")
           )
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

  test "slot endpoints start, inspect, and stop parallel read slots while overview stays slot-aware" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "service slot fixture"])
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0, shell_driver_enabled: true)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    first =
      post_json!(base_url <> "/api/slots", %{
        "lane" => "checklist",
        "action" => "plan",
        "surface" => "ui"
      })

    second =
      post_json!(base_url <> "/api/slots", %{
        "lane" => "checklist",
        "action" => "plan",
        "surface" => "openclaw"
      })

    first_slot_id = first["data"]["slot_id"]
    second_slot_id = second["data"]["slot_id"]
    assert is_binary(first_slot_id)
    assert is_binary(second_slot_id)
    assert first_slot_id != second_slot_id

    wait_until(fn ->
      slots = get_json!(base_url <> "/api/slots")["data"]
      slots["counts"]["active"] >= 2
    end, 5_000)

    overview = get_json!(base_url <> "/api/overview")
    assert overview["data"]["slots"]["counts"]["active"] >= 2
    assert overview["data"]["runtime_state"]["mode"] == "slots"
    assert overview["data"]["runtime_state"]["transition"] == "coordinating"
    assert overview["data"]["runtime_owner"]["current"]["owner"] == "slots"

    slots_payload = get_json!(base_url <> "/api/slots")["data"]

    slot_summary =
      Enum.find(slots_payload["items"], fn item -> item["slot_id"] == first_slot_id end)

    detail = get_json!(base_url <> "/api/slots/#{first_slot_id}")
    assert detail["data"]["slot_id"] == first_slot_id
    assert detail["data"]["lane"] == "checklist"
    assert detail["data"]["action"] == "plan"
    assert detail["data"]["runtime_surface"] == "ui"
    assert is_binary(detail["data"]["worktree_path"])
    assert String.starts_with?(slot_summary["slot_paths"]["root"], config.v2_state_dir)
    assert detail["data"]["coordination_paths"]["requests"] != config.requests_file

    stop_payload = post_json!(base_url <> "/api/slots/#{first_slot_id}/stop", %{"reason" => "kill"})
    assert stop_payload["data"]["slot_id"] == first_slot_id

    Process.sleep(100)

    first_after_stop = get_json!(base_url <> "/api/slots/#{first_slot_id}")
    second_after_stop = get_json!(base_url <> "/api/slots/#{second_slot_id}")

    refute first_after_stop["data"]["status"] == "running"
    assert second_after_stop["data"]["status"] in ["running", "stopping", "stopped", "completed", "blocked"]

    _ = post_json!(base_url <> "/api/slots/#{second_slot_id}/stop", %{"reason" => "kill"})

    assert File.read!(config.requests_file) == ""
    assert File.read!(config.questions_file) == ""
    assert File.read!(config.escalations_file) == ""
  end

  test "workflow preflight slots use the slot service endpoints without mutating canonical files" do
    repo = create_git_repo_fixture!(plan_content: "# done\n")
    create_workflow_package!(repo.repo_root, "alpha")

    runner_path =
      write_executable!(Path.join(repo.repo_root, "bin/workflow-runner"), """
      #!/usr/bin/env bash
      set -euo pipefail
      sleep 1
      echo "workflow:$FORGELOOP_WORKFLOW_NAME:$FORGELOOP_RUNTIME_MODE"
      """)

    layout = create_ui_layout!(repo.repo_root)

    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "workflow slot fixture"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        workflow_runner: runner_path,
        shell_driver_enabled: false
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    payload =
      post_json!(base_url <> "/api/slots", %{
        "lane" => "workflow",
        "action" => "preflight",
        "workflow_name" => "alpha",
        "surface" => "service"
      })

    slot_id = payload["data"]["slot_id"]
    assert payload["data"]["lane"] == "workflow"
    assert payload["data"]["action"] == "preflight"

    wait_until(fn ->
      status = get_json!(base_url <> "/api/slots/#{slot_id}")["data"]["status"]
      status == "completed"
    end, 5_000)

    detail = get_json!(base_url <> "/api/slots/#{slot_id}")
    assert detail["data"]["workflow_name"] == "alpha"
    assert detail["data"]["coordination_paths"]["requests"] != config.requests_file
    assert File.read!(config.requests_file) == ""
    assert File.read!(config.questions_file) == ""
    assert File.read!(config.escalations_file) == ""
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

    {:ok, daemon_pid} =
      Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)

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

    {:ok, daemon_pid} =
      Daemon.start_link(config: config, driver: ForgeloopV2.WorkDrivers.Noop, schedule: false)

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

  test "live conflicting runtime owners block all manual start surfaces consistently" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    create_workflow_package!(repo.repo_root, "alpha")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    claim = write_runtime_claim!(config, owner: "bash", mode: "daemon")

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    overview = get_json!(base_url <> "/api/overview")
    assert overview["data"]["runtime_owner"]["state"] == "live"
    assert overview["data"]["runtime_owner"]["error"] == nil
    assert overview["data"]["runtime_owner"]["live?"] == true
    assert overview["data"]["runtime_owner"]["start_allowed?"] == false
    assert overview["data"]["runtime_owner"]["current"]["owner"] == "bash"
    assert overview["data"]["runtime_owner"]["current"]["claim_id"] == claim["claim_id"]
    assert overview["data"]["ownership"]["summary_state"] == "blocked"
    assert overview["data"]["ownership"]["start_gate"]["status"] == "blocked"
    assert overview["data"]["ownership"]["start_gate"]["reason"] == "active_runtime_owned_by"
    assert overview["data"]["ownership"]["runtime_owner"]["owner"] == "bash"

    for {path, body} <- [
          {"/api/control/run", %{"mode" => "build"}},
          {"/api/babysitter/start", %{"mode" => "build"}},
          {"/api/workflows/alpha/preflight", %{}}
        ] do
      conflict = post_json_response!(base_url <> path, body)
      assert conflict.status == 409
      assert conflict.body["error"]["reason"] == "active_runtime_owned_by"
      assert conflict.body["error"]["details"]["owner"] == "bash"
      assert conflict.body["error"]["ownership"]["summary_state"] == "blocked"
      assert conflict.body["error"]["ownership"]["start_gate"]["reason"] == "active_runtime_owned_by"
    end
  end

  test "reclaimable runtime owners stay visible without blocking managed starts" do
    repo = create_git_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    write_runtime_claim_payload!(config, %{
      "schema_version" => 2,
      "claim_id" => "rt-reclaimable",
      "owner" => "bash",
      "surface" => "daemon",
      "mode" => "build",
      "branch" => config.default_branch,
      "pid" => 999_999,
      "process_pid" => nil,
      "host" => local_host_name!(),
      "started_at" => ago_iso!(300),
      "updated_at" => ago_iso!(300)
    })

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    overview = get_json!(base_url <> "/api/overview")
    assert overview["data"]["runtime_owner"]["state"] == "reclaimable"
    assert overview["data"]["runtime_owner"]["error"] == nil
    assert overview["data"]["runtime_owner"]["reclaimable?"] == true
    assert overview["data"]["runtime_owner"]["start_allowed?"] == true
    assert overview["data"]["ownership"]["summary_state"] == "recoverable"
    assert overview["data"]["ownership"]["start_gate"]["status"] == "allowed"
    assert overview["data"]["ownership"]["start_gate"]["reclaim_on_start?"] == true

    assert post_json!(base_url <> "/api/control/run", %{"mode" => "build"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
  end

  test "malformed runtime ownership stays visible and blocks manual starts fail-closed" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    create_workflow_package!(repo.repo_root, "alpha")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    write_raw_runtime_claim!(config, "{not-json\n")

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    overview = get_json!(base_url <> "/api/overview")
    assert overview["data"]["runtime_owner"]["state"] == "error"
    assert is_binary(overview["data"]["runtime_owner"]["error"])
    assert overview["data"]["runtime_owner"]["start_allowed?"] == false
    assert overview["data"]["ownership"]["summary_state"] == "error"
    assert overview["data"]["ownership"]["start_gate"]["reason"] == "active_runtime_state_error"

    for {path, body} <- [
          {"/api/control/run", %{"mode" => "build"}},
          {"/api/babysitter/start", %{"mode" => "build"}},
          {"/api/workflows/alpha/preflight", %{}}
        ] do
      response = post_json_response!(base_url <> path, body)
      assert response.status == 500
      assert response.body["error"]["reason"] == "active_runtime_state_error"
      assert response.body["error"]["details"]["state"] == "error"
      assert response.body["error"]["ownership"]["summary_state"] == "error"
      assert response.body["error"]["ownership"]["start_gate"]["reason"] == "active_runtime_state_error"
    end
  end

  test "stale active-run metadata is visible but not treated as running and is cleaned before start" do
    repo = create_git_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    write_active_run!(config, last_heartbeat_at: ago_iso!(300), runtime_surface: "ui")

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    overview = get_json!(base_url <> "/api/overview")["data"]
    babysitter = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter["running?"] == false
    assert babysitter["active_run_state"] == "stale"
    assert babysitter["active_run_error"] == nil
    assert babysitter["active_run"]["runtime_surface"] == "ui"
    assert overview["ownership"]["summary_state"] == "recoverable"
    assert overview["ownership"]["start_gate"]["cleanup_on_start?"] == true
    assert overview["ownership"]["active_run"]["state"] == "stale"

    assert post_json!(base_url <> "/api/babysitter/start", %{"mode" => "build"})["ok"] == true
    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)

    refreshed = get_json!(base_url <> "/api/babysitter")["data"]
    assert refreshed["active_run_state"] == "missing"
    refute File.exists?(Worktree.active_run_path(config))
  end

  test "malformed active-run metadata stays visible and blocks manual starts fail-closed" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    create_workflow_package!(repo.repo_root, "alpha")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    write_raw_active_run!(config, "{broken\n")

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    overview = get_json!(base_url <> "/api/overview")
    assert overview["data"]["runtime_owner"]["start_allowed?"] == false
    assert overview["data"]["ownership"]["summary_state"] == "error"
    assert overview["data"]["ownership"]["start_gate"]["reason"] == "active_run_state_error"

    babysitter = get_json!(base_url <> "/api/babysitter")["data"]
    assert babysitter["running?"] == false
    assert babysitter["active_run_state"] == "error"
    assert is_binary(babysitter["active_run_error"])

    for {path, body} <- [
          {"/api/control/run", %{"mode" => "build"}},
          {"/api/babysitter/start", %{"mode" => "build"}},
          {"/api/workflows/alpha/preflight", %{}}
        ] do
      response = post_json_response!(base_url <> path, body)
      assert response.status == 500
      assert response.body["error"]["reason"] == "active_run_state_error"
      assert response.body["error"]["details"] =~ "invalid_active_run"
      assert response.body["error"]["ownership"]["summary_state"] == "error"
      assert response.body["error"]["ownership"]["start_gate"]["reason"] == "active_run_state_error"
    end
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

    wait_until(
      fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end,
      4_000
    )

    assert File.read!(Path.join([config.runtime_dir, "workflows", "alpha", "last-preflight.txt"])) =~
             "ok:preflight:alpha"

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

    invalid_runner_args =
      post_json_response!(base_url <> "/api/workflows/alpha/run", %{"runner_args" => [1]})

    assert invalid_runner_args.status == 400
    assert invalid_runner_args.body["error"]["reason"] == "invalid_runner_args"
    refute Map.has_key?(invalid_runner_args.body["error"], "ownership")

    missing = post_json_response!(base_url <> "/api/workflows/missing/run", %{})
    assert missing.status == 404
    assert missing.body["error"]["reason"] == "workflow_not_found"
    refute Map.has_key?(missing.body["error"], "ownership")
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

    start_payload =
      post_json!(base_url <> "/api/control/run", %{"mode" => "build", "surface" => "openclaw"})

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

    wait_until(
      fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end,
      4_000
    )

    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.questions_file) =~ "## Q-"
    assert File.read!(config.escalations_file) =~ "## E-"

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "awaiting-human"
    assert state.surface == "ui"
  end

  test "coordination endpoint exposes shared advisory state and overview embeds it" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok =
      Events.emit(config, :daemon_tick, %{
        "action" => "build",
        "reason" => "Backlog still needs work.",
        "recorded_at" => "2026-03-21T10:09:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "clear_pause",
        "recorded_at" => "2026-03-21T10:10:00Z"
      })

    coordination_payload = get_json!(base_url <> "/api/coordination?limit=5")
    assert coordination_payload["ok"] == true
    assert coordination_payload["data"]["schema_version"] == 1
    assert coordination_payload["data"]["status"] == "actionable"
    assert coordination_payload["data"]["event_source"] == "events_api"
    assert coordination_payload["data"]["summary"]["recommendations"] == 1
    assert coordination_payload["data"]["brief"] =~ "Actionable: Queue the next rebuild pass"

    assert Enum.map(coordination_payload["data"]["timeline"], & &1["event_code"]) == [
             "daemon_tick",
             "operator_action"
           ]

    assert Enum.at(coordination_payload["data"]["timeline"], 0)["title"] == "Daemon decided Build"

    assert coordination_payload["data"]["playbooks"] |> Enum.at(0) |> Map.fetch!("id") ==
             "post_clear_pause_rebuild"

    assert coordination_payload["data"]["cursor"]["requested_after"] == nil

    overview_payload = get_json!(base_url <> "/api/overview?limit=5")
    assert overview_payload["ok"] == true
    assert overview_payload["data"]["coordination"]["status"] == "actionable"

    assert overview_payload["data"]["coordination"]["brief"] ==
             coordination_payload["data"]["brief"]

    assert overview_payload["data"]["coordination"]["timeline"] ==
             coordination_payload["data"]["timeline"]

    assert overview_payload["data"]["coordination"]["cursor"]["next_after"] ==
             overview_payload["data"]["events_meta"]["latest_event_id"]

    assert overview_payload["data"]["coordination"]["summary"]["playbooks"]["actionable"] == 1
  end

  test "coordination endpoint rejects invalid playbook filters" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    response = get_response_raw!(base_url <> "/api/coordination?playbook_id=not-a-playbook")
    assert response.status == 400
    assert response.body["ok"] == false
    assert response.body["api"]["contract_version"] == 1
    assert response.body["error"]["reason"] == "invalid_coordination_playbook"
  end

  test "events endpoint exposes bounded tail and replay metadata" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok =
      Events.emit(config, :daemon_tick, %{
        "action" => "first",
        "recorded_at" => "2026-03-21T10:00:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "second",
        "recorded_at" => "2026-03-21T10:01:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "third",
        "recorded_at" => "2026-03-21T10:02:00Z"
      })

    tail_payload = get_json!(base_url <> "/api/events?limit=2")
    assert tail_payload["ok"] == true
    assert tail_payload["api"]["contract_version"] == 1
    assert Enum.map(tail_payload["data"], & &1["action"]) == ["second", "third"]
    assert tail_payload["meta"]["returned_count"] == 2
    assert tail_payload["meta"]["truncated?"] == true

    replay_cursor = Enum.at(tail_payload["data"], 0)["event_id"]

    replay_payload =
      get_json!(base_url <> "/api/events?after=#{URI.encode_www_form(replay_cursor)}&limit=5")

    assert replay_payload["ok"] == true
    assert replay_payload["meta"]["cursor_found?"] == true
    assert Enum.map(replay_payload["data"], & &1["action"]) == ["third"]

    blank_after_payload = get_json!(base_url <> "/api/events?after=%20%20&limit=2")
    assert blank_after_payload["ok"] == true
    assert Enum.map(blank_after_payload["data"], & &1["action"]) == ["second", "third"]

    latest_cursor = Enum.at(replay_payload["data"], -1)["event_id"]

    latest_payload =
      get_json!(base_url <> "/api/events?after=#{URI.encode_www_form(latest_cursor)}&limit=5")

    assert latest_payload["ok"] == true
    assert latest_payload["meta"]["cursor_found?"] == true
    assert latest_payload["data"] == []

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
    assert first =~ ~s("contract_version":1)
    assert first =~ "pending task"

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "stream_probe",
        "recorded_at" => "2026-03-21T10:03:00Z"
      })

    second = recv_until(socket, "stream_probe", 4_000)
    assert second =~ "event: event"
    assert second =~ ~s("contract_version":1)
    assert second =~ "id: evt-"
    assert second =~ "stream_probe"
  end

  test "stream endpoint replays missed events when a cursor is supplied" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "resume_probe_one",
        "recorded_at" => "2026-03-21T10:04:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "resume_probe_two",
        "recorded_at" => "2026-03-21T10:05:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "resume_probe_three",
        "recorded_at" => "2026-03-21T10:06:00Z"
      })

    events_payload = get_json!(base_url <> "/api/events?limit=5")

    after_cursor =
      Enum.find(events_payload["data"], &(&1["action"] == "resume_probe_one"))["event_id"]

    {:ok, socket} =
      open_stream_socket(
        base_url <> "/api/stream?limit=5&after=#{URI.encode_www_form(after_cursor)}"
      )

    on_exit(fn -> :gen_tcp.close(socket) end)

    replay = recv_until(socket, "resume_probe_two", 4_000)
    refute replay =~ "event: snapshot"
    assert replay =~ "event: event"
    assert replay =~ "resume_probe_two"

    :gen_tcp.close(socket)

    {:ok, header_socket} =
      open_stream_socket(base_url <> "/api/stream?limit=5", [{"last-event-id", after_cursor}])

    on_exit(fn -> :gen_tcp.close(header_socket) end)

    header_replay = recv_until(header_socket, "resume_probe_two", 4_000)
    refute header_replay =~ "event: snapshot"
    assert header_replay =~ "resume_probe_two"
  end

  test "stream endpoint falls back to a snapshot when replay cursors are missing or truncated" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "gap_one",
        "recorded_at" => "2026-03-21T10:07:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "gap_two",
        "recorded_at" => "2026-03-21T10:08:00Z"
      })

    :ok =
      Events.emit(config, :operator_action, %{
        "action" => "gap_three",
        "recorded_at" => "2026-03-21T10:09:00Z"
      })

    payload = get_json!(base_url <> "/api/events?limit=5")
    first_cursor = Enum.find(payload["data"], &(&1["action"] == "gap_one"))["event_id"]

    {:ok, missing_socket} =
      open_stream_socket(base_url <> "/api/stream?limit=5&after=evt-missing")

    on_exit(fn -> :gen_tcp.close(missing_socket) end)
    missing_stream = recv_until(missing_socket, "event: snapshot", 4_000)
    assert missing_stream =~ "event: snapshot"

    {:ok, truncated_socket} =
      open_stream_socket(
        base_url <> "/api/stream?limit=1&after=#{URI.encode_www_form(first_cursor)}"
      )

    on_exit(fn -> :gen_tcp.close(truncated_socket) end)
    truncated_stream = recv_until(truncated_socket, "event: snapshot", 4_000)
    assert truncated_stream =~ "event: snapshot"
  end

  defp start_service!(config) do
    {:ok, pid} =
      Service.start_link(
        config: config,
        port: config.service_port,
        host: config.service_host,
        name: nil,
        control_plane_name: nil
      )

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
    response = get_response_raw!(url)
    assert response.status == 200
    response
  end

  defp get_response_raw!(url) do
    request!(:get, url, nil)
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
          "GET ",
          uri.path || "/",
          query_suffix(uri.query),
          " HTTP/1.1\r\n",
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
          "POST ",
          uri.path || "/",
          query_suffix(uri.query),
          " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "content-type: application/json\r\n",
          "content-length: ",
          Integer.to_string(byte_size(body)),
          "\r\n",
          "connection: close\r\n\r\n",
          body
        ]
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    decode_response(response)
  end

  defp open_stream_socket(url, headers \\ []) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    header_lines =
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

    :ok =
      :gen_tcp.send(
        socket,
        [
          "GET ",
          uri.path || "/",
          query_suffix(uri.query),
          " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "accept: text/event-stream\r\n",
          header_lines,
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
        {:ok, chunk} ->
          recv_until(socket, needle, timeout_ms, acc <> chunk)

        {:error, reason} ->
          raise "stream closed before #{inspect(needle)}: #{inspect(reason)}\n#{acc}"
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
