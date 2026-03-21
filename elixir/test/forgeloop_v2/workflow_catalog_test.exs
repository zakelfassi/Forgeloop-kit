defmodule ForgeloopV2.WorkflowCatalogTest do
  use ForgeloopV2.TestSupport

  test "lists valid workflow packages from canonical workflows root" do
    repo = create_repo_fixture!()
    create_workflow_package!(repo.repo_root, "alpha", prompts?: true, scripts?: true)
    create_workflow_package!(repo.repo_root, "zeta")
    create_workflow_package!(repo.repo_root, "incomplete", config?: false)
    create_workflow_package!(repo.repo_root, "bad name")
    config = config_for!(repo.repo_root)

    assert Enum.map(WorkflowCatalog.list(config), & &1.name) == ["alpha", "zeta"]

    assert {:ok, entry} = WorkflowCatalog.fetch(config, "alpha")
    assert String.ends_with?(entry.graph_file, "workflow.dot")
    assert String.ends_with?(entry.config_file, "workflow.toml")
    assert String.ends_with?(entry.prompts_dir, "prompts")
    assert String.ends_with?(entry.scripts_dir, "scripts")
    assert entry.runner_kind == :workflow_pack_runner
  end

  test "fetch returns missing for absent package and rejects invalid names" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert :missing = WorkflowCatalog.fetch(config, "missing")
    assert {:error, {:invalid_workflow_name, "../escape"}} = WorkflowCatalog.fetch(config, "../escape")
  end

  test "default detection only searches canonical workflows root" do
    repo = create_repo_fixture!()

    config = config_for!(repo.repo_root)
    assert config.workflow_dir == Path.join(repo.repo_root, "workflows")
    assert config.workflow_search_dirs == [Path.join(repo.repo_root, "workflows")]
    assert :missing = WorkflowCatalog.fetch(config, "legacy")
  end

  test "explicit workflow_dir overrides detection" do
    repo = create_repo_fixture!()
    File.mkdir_p!(Path.join(repo.repo_root, "workflows"))
    explicit_dir = Path.join(repo.repo_root, "custom-workflows")
    File.mkdir_p!(explicit_dir)

    config = config_for!(repo.repo_root, workflow_dir: explicit_dir)
    assert config.workflow_dir == explicit_dir
    assert config.workflow_search_dirs == [explicit_dir]
  end
end
