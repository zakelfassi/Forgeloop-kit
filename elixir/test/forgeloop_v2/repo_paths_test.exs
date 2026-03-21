defmodule ForgeloopV2.RepoPathsTest do
  use ForgeloopV2.TestSupport

  test "resolves repo-root install layout" do
    repo = create_repo_fixture!()
    File.mkdir_p!(Path.join(repo.repo_root, "elixir"))
    File.write!(Path.join(repo.repo_root, "config.sh"), "# config\n")

    assert {:ok, resolved} = RepoPaths.resolve(app_root: Path.join(repo.repo_root, "elixir"))
    assert resolved.repo_root == repo.repo_root
    assert resolved.forgeloop_root == repo.repo_root
  end

  test "resolves vendored repo/forgeloop/elixir layout" do
    repo = create_repo_fixture!()
    vendored_root = Path.join(repo.repo_root, "forgeloop")
    File.mkdir_p!(Path.join(vendored_root, "elixir"))
    File.write!(Path.join(vendored_root, "config.sh"), "# config\n")

    assert {:ok, resolved} = RepoPaths.resolve(app_root: Path.join(vendored_root, "elixir"))
    assert resolved.repo_root == repo.repo_root
    assert resolved.forgeloop_root == vendored_root
  end

  test "blank exported runtime-state env falls back to runtime dir default" do
    repo = create_repo_fixture!()

    File.mkdir_p!(Path.join(repo.repo_root, "elixir"))

    File.write!(
      Path.join(repo.repo_root, "config.sh"),
      """
      export FORGELOOP_RUNTIME_DIR=\"${FORGELOOP_RUNTIME_DIR:-.forgeloop}\"
      export FORGELOOP_RUNTIME_STATE_FILE=\"${FORGELOOP_RUNTIME_STATE_FILE:-}\"
      """
    )

    assert {:ok, config} =
             Config.load(
               repo_root: repo.repo_root,
               app_root: Path.join(repo.repo_root, "elixir"),
               shell_driver_enabled: false
             )
    assert config.runtime_state_file == Path.join(repo.repo_root, ".forgeloop/runtime-state.json")
  end
end
