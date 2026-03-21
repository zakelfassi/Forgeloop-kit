defmodule ForgeloopV2.TrackerRepoLocalTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.Tracker
  alias ForgeloopV2.Tracker.Issue
  alias ForgeloopV2.Tracker.RepoLocal
  alias ForgeloopV2.Tracker.Service

  test "repo-local tracker projects canonical backlog items and workflow packs" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ] Ship tracker seam
          - [ ] Keep it read-only
        - [x] Completed item
        """
      )

    create_workflow_package!(repo.repo_root, "issue-to-pr")
    config = config_for!(repo.repo_root)

    assert {:ok, overview} = RepoLocal.overview(config)
    assert overview.counts.total == 2
    assert overview.counts.backlog == 1
    assert overview.counts.workflows == 1
    assert overview.counts.ready == 2
    assert overview.sources.backlog.kind == :implementation_plan
    assert overview.sources.workflows.kind == :workflow_catalog
    assert overview.sources.workflows.path == config.workflow_dir

    assert [%Issue{} = plan_issue, %Issue{} = workflow_issue] = overview.issues

    assert plan_issue.id == "plan:2"
    assert plan_issue.identifier == "IMPLEMENTATION_PLAN.md:2"
    assert plan_issue.state == "ready"
    assert plan_issue.workflow_state == :plan_item
    assert "canonical-backlog" in plan_issue.labels
    assert plan_issue.description =~ "Pending child items"
    assert plan_issue.description =~ "Keep it read-only"

    assert workflow_issue.id == "workflow:issue-to-pr"
    assert workflow_issue.identifier == "workflow:issue-to-pr"
    assert workflow_issue.state == "ready"
    assert workflow_issue.workflow_state == :workflow_pack
    assert "workflow-pack" in workflow_issue.labels
    assert workflow_issue.description =~ "Workflow root: workflows/issue-to-pr"
    assert workflow_issue.description =~ "Graph file: workflows/issue-to-pr/workflow.dot"
  end

  test "repo-local tracker stays fail-closed when the canonical backlog is unreadable" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root, plan_file: ".")

    assert {:ok, overview} = RepoLocal.overview(config)
    assert overview.counts.total == 1
    assert overview.counts.backlog == 1
    assert overview.counts.blocked == 1
    assert [%Issue{id: "plan:alert", state: "blocked", workflow_state: :backlog_alert} = issue] = overview.issues
    assert issue.title == "Canonical backlog unreadable"
  end

  test "repo-local tracker acts as a read-only tracker adapter when configured" do
    repo = create_repo_fixture!(plan_content: "- [ ] Ship tracker seam\n")
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root)

    Application.put_env(:forgeloop_v2, :tracker_repo_local_config, config)
    Application.put_env(:forgeloop_v2, :tracker_adapter, ForgeloopV2.Tracker.RepoLocal)

    on_exit(fn ->
      Application.delete_env(:forgeloop_v2, :tracker_repo_local_config)
      Application.delete_env(:forgeloop_v2, :tracker_adapter)
    end)

    assert {:ok, issues} = Tracker.fetch_candidate_issues()
    assert length(issues) == 2
    assert {:ok, filtered} = Tracker.fetch_issues_by_states(["ready"])
    assert length(filtered) == 2
    assert {:ok, [%Issue{id: "workflow:alpha"}]} = Tracker.fetch_issue_states_by_ids(["workflow:alpha"])
    assert {:ok, %RepoLocal.Overview{counts: %{total: 2}}} = Service.repo_local_overview(config)
    assert {:error, :read_only_tracker} = Tracker.create_comment("plan:1", "hello")
    assert {:error, :read_only_tracker} = Tracker.update_issue_state("plan:1", "done")
  end
end
