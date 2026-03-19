defmodule ForgeloopV2.WorkspaceTest do
  use ForgeloopV2.TestSupport

  test "workspace metadata is deterministic and rooted under v2 workspaces" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert {:ok, workspace} = Workspace.from_config(config, branch: "main", mode: "build", kind: "build")
    assert workspace.workspace_id =~ "main"
    assert workspace.workspace_root == Path.join(config.v2_state_dir, "workspaces")
  end

  test "path policy rejects symlink escapes outside allowed roots" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    workspace_root = Path.join(config.v2_state_dir, "workspaces")
    File.mkdir_p!(workspace_root)

    external_root = Path.join(repo.repo_root, "external")
    File.mkdir_p!(external_root)
    symlink_path = Path.join(workspace_root, "escape-link")
    File.ln_s!(external_root, symlink_path)

    assert {:error, {:path_resolves_outside_allowed_root, _, _}} =
             PathPolicy.validate_owned_path(config, Path.join(symlink_path, "nested"), :workspace)
  end
end
