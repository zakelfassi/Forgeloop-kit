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
end
