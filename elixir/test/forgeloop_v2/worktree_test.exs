defmodule ForgeloopV2.WorktreeTest do
  use ForgeloopV2.TestSupport

  test "prepare and cleanup manage a disposable worktree under the workspace root" do
    repo = create_git_repo_fixture!()
    config = config_for!(repo.repo_root)

    {:ok, workspace} =
      Workspace.from_config(config, branch: "main", mode: "build", kind: "babysitter")

    assert {:ok, handle} = Worktree.prepare(config, workspace)
    assert String.starts_with?(handle.checkout_path, PathPolicy.workspace_root(config) <> "/")
    assert File.dir?(handle.checkout_path)
    assert File.exists?(handle.metadata_file)

    assert :ok = Worktree.cleanup(config, handle)
    refute File.exists?(handle.checkout_path)
    refute File.exists?(handle.metadata_file)
  end

  test "dirty source changes still block worktree prepare" do
    repo = create_git_repo_fixture!()
    config = config_for!(repo.repo_root)

    {:ok, workspace} =
      Workspace.from_config(config, branch: "main", mode: "build", kind: "babysitter")

    File.write!(Path.join(repo.repo_root, "src.txt"), "dirty\n")

    assert {:error, {:dirty_repo, dirty_lines}} = Worktree.prepare(config, workspace)
    assert Enum.any?(dirty_lines, &String.contains?(&1, "src.txt"))
  end

  test "canonical control-file dirt does not block worktree prepare" do
    repo = create_git_repo_fixture!(plan_content: "- [ ] pending\n")
    config = config_for!(repo.repo_root)

    {:ok, workspace} =
      Workspace.from_config(config, branch: "main", mode: "build", kind: "babysitter")

    File.write!(config.requests_file, "[PAUSE]\n")
    File.write!(config.questions_file, "## Q-1\n**Status**: ⏳ Awaiting response\n")

    assert {:ok, handle} = Worktree.prepare(config, workspace)
    assert :ok = Worktree.cleanup(config, handle)
  end

  test "cleanup_stale removes stale active run metadata and checkout" do
    repo = create_git_repo_fixture!()
    config = config_for!(repo.repo_root)

    {:ok, workspace} =
      Workspace.from_config(config, branch: "main", mode: "build", kind: "babysitter")

    {:ok, handle} = Worktree.prepare(config, workspace)

    File.mkdir_p!(Path.dirname(Worktree.active_run_path(config)))

    File.write!(
      Worktree.active_run_path(config),
      Jason.encode!(%{"workspace_id" => workspace.workspace_id}, pretty: true) <> "\n"
    )

    assert {:ok, cleaned_ids} = Worktree.cleanup_stale(config)
    assert workspace.workspace_id in cleaned_ids
    refute File.exists?(handle.checkout_path)
    refute File.exists?(handle.metadata_file)
    refute File.exists?(Worktree.active_run_path(config))
  end

  test "active_run_state classifies stale heartbeat payloads" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    payload = write_active_run!(config, last_heartbeat_at: ago_iso!(300))

    assert {:stale, active_run} = Worktree.active_run_state(config)
    assert active_run["workspace_id"] == payload["workspace_id"]
  end

  test "active_run_state surfaces malformed payload errors" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    write_raw_active_run!(config, "{broken\n")

    assert {:error, _reason} = Worktree.active_run_state(config)
  end
end
