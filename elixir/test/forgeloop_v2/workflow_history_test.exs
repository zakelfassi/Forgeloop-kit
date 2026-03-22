defmodule ForgeloopV2.WorkflowHistoryTest do
  use ForgeloopV2.TestSupport

  test "fetch returns a missing snapshot when no workflow history exists yet" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)

    assert {:ok, snapshot} = WorkflowHistory.fetch(config, "alpha")
    assert snapshot.status == :missing
    assert snapshot.entries == []
    assert snapshot.counts.total == 0
  end

  test "record_terminal_outcome persists bounded deduped workflow history" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)
    {:ok, run_spec} = RunSpec.workflow(:run, "alpha")

    workflow_root = Path.join([config.runtime_dir, "workflows", "alpha"])
    File.mkdir_p!(workflow_root)
    File.write!(Path.join(workflow_root, "last-run.txt"), "ok\n")

    assert :ok =
             WorkflowHistory.record_terminal_outcome(config, run_spec,
               run_id: "wf-alpha-1",
               outcome: :succeeded,
               runtime_surface: "ui",
               branch: "main",
               started_at: "2026-03-21T00:00:00Z",
               finished_at: "2026-03-21T00:00:01Z",
               summary: "workflow completed"
             )

    assert :ok =
             WorkflowHistory.record_terminal_outcome(config, run_spec,
               run_id: "wf-alpha-1",
               outcome: :failed,
               runtime_surface: "daemon",
               branch: "main",
               started_at: "2026-03-21T00:00:00Z",
               finished_at: "2026-03-21T00:00:02Z",
               summary: "duplicate should noop"
             )

    assert {:ok, snapshot} = WorkflowHistory.fetch(config, "alpha")
    assert snapshot.status == :available
    assert snapshot.returned_count == 1
    assert snapshot.retained_count == 1
    assert snapshot.latest.run_id == "wf-alpha-1"
    assert snapshot.latest.outcome == :succeeded
    assert snapshot.latest.artifact.status == :available
    assert snapshot.counts.succeeded == 1
  end

  test "start_failed history does not attach stale artifacts from an older attempt" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)
    {:ok, run_spec} = RunSpec.workflow(:run, "alpha")

    workflow_root = Path.join([config.runtime_dir, "workflows", "alpha"])
    File.mkdir_p!(workflow_root)
    File.write!(Path.join(workflow_root, "last-run.txt"), "stale\n")

    assert :ok =
             WorkflowHistory.record_terminal_outcome(config, run_spec,
               run_id: "wf-alpha-start-failed",
               outcome: :start_failed,
               runtime_surface: "daemon",
               branch: "main",
               started_at: "2099-01-01T00:00:00Z",
               finished_at: "2099-01-01T00:00:01Z",
               summary: "start failed"
             )

    assert {:ok, snapshot} = WorkflowHistory.fetch(config, "alpha")
    assert snapshot.latest.run_id == "wf-alpha-start-failed"
    assert snapshot.latest.outcome == :start_failed
    assert snapshot.latest.artifact == nil
  end
end
