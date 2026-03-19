defmodule ForgeloopV2.WorkflowTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.{Workflow, WorkflowStore}

  test "loads workflow front matter and prompt" do
    repo = create_repo_fixture!()
    workflow_file = Path.join(repo.repo_root, "WORKFLOW.md")

    File.write!(
      workflow_file,
      """
      ---
      tracker:
        kind: memory
      agent:
        max_turns: 12
      ---
      You are working on issue {{ issue.identifier }}.
      """
    )

    assert {:ok, workflow} = Workflow.load(workflow_file)
    assert workflow.config["tracker"]["kind"] == "memory"
    assert workflow.config["agent"]["max_turns"] == 12
    assert workflow.spec.version == 1
    assert workflow.spec.tracker["kind"] == "memory"
    assert workflow.prompt =~ "issue {{ issue.identifier }}"
  end

  test "rejects service-owned workflow fields and unsupported versions" do
    repo = create_repo_fixture!()
    workflow_file = Path.join(repo.repo_root, "WORKFLOW.md")

    File.write!(
      workflow_file,
      """
      ---
      runtime:
        interval: 5
      ---
      Prompt
      """
    )

    assert {:error, {:workflow_forbidden_keys, ["runtime"]}} = Workflow.load(workflow_file)

    File.write!(
      workflow_file,
      """
      ---
      version: 2
      tracker:
        kind: memory
      ---
      Prompt
      """
    )

    assert {:error, {:unsupported_workflow_version, 2}} = Workflow.load(workflow_file)
  end

  test "workflow store keeps last known good config on reload failure" do
    repo = create_repo_fixture!()
    workflow_file = Path.join(repo.repo_root, "WORKFLOW.md")

    File.write!(
      workflow_file,
      """
      ---
      tracker:
        kind: memory
      ---
      Prompt v1
      """
    )

    Workflow.set_workflow_file_path(workflow_file)
    {:ok, pid} = WorkflowStore.start_link(name: WorkflowStore)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Workflow.clear_workflow_file_path()
    end)

    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Prompt v1"

    File.write!(workflow_file, "---\ntracker: [\n---\nBroken")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Prompt v1"
  end

  test "workflow store keeps last known good config on semantic validation failure" do
    repo = create_repo_fixture!()
    workflow_file = Path.join(repo.repo_root, "WORKFLOW.md")

    File.write!(
      workflow_file,
      """
      ---
      tracker:
        kind: memory
      ---
      Prompt v1
      """
    )

    Workflow.set_workflow_file_path(workflow_file)
    {:ok, pid} = WorkflowStore.start_link(name: WorkflowStore)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Workflow.clear_workflow_file_path()
    end)

    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Prompt v1"

    File.write!(
      workflow_file,
      """
      ---
      workspace:
        root: /tmp/nope
      ---
      Prompt v2
      """
    )

    assert {:error, {:workflow_forbidden_keys, ["workspace"]}} = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Prompt v1"
  end
end
