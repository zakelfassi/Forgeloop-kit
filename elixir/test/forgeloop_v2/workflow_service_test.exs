defmodule ForgeloopV2.WorkflowServiceTest do
  use ForgeloopV2.TestSupport

  test "list returns catalog entries with missing snapshots by default" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    create_workflow_package!(repo.repo_root, "zeta")
    create_workflow_package!(repo.repo_root, "bad name")
    config = config_for!(repo.repo_root)

    assert {:ok, workflows} = WorkflowService.list(config)
    assert Enum.map(workflows, & &1.entry.name) == ["alpha", "zeta"]

    Enum.each(workflows, fn summary ->
      assert summary.preflight.status == :missing
      assert summary.run.status == :missing
      assert summary.preflight.output == nil
      assert summary.run.output == nil
      assert summary.history.status == :missing
      assert summary.history.entries == []
      assert summary.latest_activity_kind == nil
      assert summary.latest_activity_at == nil
    end)
  end

  test "fetch returns artifact metadata by default and output when requested" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)
    workflow_runtime_dir = Path.join([config.runtime_dir, "workflows", "alpha"])
    File.mkdir_p!(workflow_runtime_dir)

    preflight_path = Path.join(workflow_runtime_dir, "last-preflight.txt")
    run_path = Path.join(workflow_runtime_dir, "last-run.txt")

    File.write!(preflight_path, "preflight ok\n")
    Process.sleep(1_100)
    File.write!(run_path, "run ok\n")

    create_workflow_history!(config, "alpha", [
      [action: :preflight, outcome: :succeeded, runtime_surface: "workflow", summary: "preflight ok"],
      [action: :run, outcome: :succeeded, runtime_surface: "workflow", summary: "run ok"]
    ])

    assert {:ok, summary} = WorkflowService.fetch(config, "alpha")
    assert summary.preflight.status == :available
    assert summary.run.status == :available
    assert summary.preflight.size_bytes == byte_size("preflight ok\n")
    assert summary.run.size_bytes == byte_size("run ok\n")
    assert is_binary(summary.preflight.updated_at)
    assert is_binary(summary.run.updated_at)
    assert summary.preflight.output == nil
    assert summary.run.output == nil
    assert summary.history.status == :available
    assert summary.history.returned_count == 2
    assert summary.history.latest.outcome == :succeeded
    assert summary.history.latest.action == :run
    assert summary.latest_activity_kind == :run
    assert is_binary(summary.latest_activity_at)

    assert {:ok, detailed} = WorkflowService.fetch(config, "alpha", include_output?: true)
    assert detailed.preflight.output == "preflight ok\n"
    assert detailed.run.output == "run ok\n"
    assert Enum.count(detailed.history.entries) == 2
  end

  test "overview exposes workflow runtime state by workflow mode even when launched from another surface" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)

    assert {:ok, _state} =
             RuntimeStateStore.write(config, %{
               status: "running",
               transition: "started",
               surface: "ui",
               mode: "workflow-run",
               reason: "alpha",
               requested_action: "",
               branch: "main"
             })

    assert {:ok, overview} = WorkflowService.overview(config)
    assert %ForgeloopV2.RuntimeState{surface: "ui", mode: "workflow-run"} = overview.runtime_state

    assert {:ok, _state} =
             RuntimeStateStore.write(config, %{
               status: "running",
               transition: "started",
               surface: "daemon",
               mode: "daemon",
               reason: "loop tick",
               requested_action: "",
               branch: "main"
             })

    assert {:ok, overview} = WorkflowService.overview(config)
    assert overview.runtime_state == nil
  end

  test "overview overlays the currently managed workflow run" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    create_workflow_package!(repo.repo_root, "zeta")
    config = config_for!(repo.repo_root)

    File.mkdir_p!(Path.dirname(Worktree.active_run_path(config)))

    File.write!(
      Worktree.active_run_path(config),
      Jason.encode!(%{
        "lane" => "workflow",
        "action" => "run",
        "mode" => "workflow-run",
        "run_id" => "wf-alpha-run-1",
        "workflow_name" => "alpha",
        "runtime_surface" => "openclaw",
        "branch" => "main",
        "started_at" => "2026-03-21T00:00:00Z",
        "last_heartbeat_at" => "2026-03-21T00:00:01Z",
        "status" => "running"
      }) <> "\n"
    )

    assert {:ok, overview} = WorkflowService.overview(config)
    [alpha, zeta] = overview.workflows
    assert alpha.entry.name == "alpha"
    assert %ForgeloopV2.WorkflowService.ActiveRun{run_id: "wf-alpha-run-1", workflow_name: "alpha", action: :run, runtime_surface: "openclaw"} = alpha.active_run
    assert zeta.active_run == nil
  end

  test "latest activity falls back to history when start failures have no output artifact" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)

    create_workflow_history!(config, "alpha", [
      [action: :run, outcome: :start_failed, runtime_surface: "daemon", summary: "start failed"]
    ])

    assert {:ok, summary} = WorkflowService.fetch(config, "alpha")
    assert summary.preflight.status == :missing
    assert summary.run.status == :missing
    assert summary.history.status == :available
    assert summary.history.latest.outcome == :start_failed
    assert summary.latest_activity_kind == :run
    assert summary.latest_activity_at == summary.history.latest.finished_at
  end

  test "fetch propagates invalid workflow names and missing workflows" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert {:error, {:invalid_workflow_name, "../escape"}} = WorkflowService.fetch(config, "../escape")
    assert :missing = WorkflowService.fetch(config, "missing")
  end

  test "symlinked artifact files degrade to per-snapshot errors without failing the overview" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)
    workflow_root = Path.join([config.runtime_dir, "workflows", "alpha"])
    escaped_file = Path.join(repo.repo_root, "outside-runtime.txt")

    File.mkdir_p!(workflow_root)
    File.write!(escaped_file, "outside\n")
    assert :ok = File.ln_s(escaped_file, Path.join(workflow_root, "last-run.txt"))

    assert {:ok, summary} = WorkflowService.fetch(config, "alpha")
    assert summary.preflight.status == :missing
    assert summary.run.status == :error
    assert match?({:symlink_artifact_path, _}, summary.run.error)

    assert {:ok, overview} = WorkflowService.overview(config)
    [alpha] = overview.workflows
    assert alpha.entry.name == "alpha"
    assert alpha.preflight.status == :missing
    assert alpha.run.status == :error
  end

  test "path escapes degrade to per-snapshot errors without failing the overview" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)
    workflow_root = Path.join([config.runtime_dir, "workflows"])
    escaped_root = Path.join(repo.repo_root, "outside-runtime")

    File.mkdir_p!(workflow_root)
    File.mkdir_p!(escaped_root)
    assert :ok = File.ln_s(escaped_root, Path.join(workflow_root, "alpha"))

    assert {:ok, summary} = WorkflowService.fetch(config, "alpha")
    assert summary.preflight.status == :error
    assert summary.run.status == :error
    assert summary.history.status == :error
    assert match?({:path_resolves_outside_allowed_root, _, _}, summary.preflight.error)
    assert match?({:path_resolves_outside_allowed_root, _, _}, summary.run.error)
    assert match?({:path_resolves_outside_allowed_root, _, _}, summary.history.error)

    assert {:ok, overview} = WorkflowService.overview(config)
    [alpha] = overview.workflows
    assert alpha.entry.name == "alpha"
    assert alpha.preflight.status == :error
    assert alpha.run.status == :error
  end
end
