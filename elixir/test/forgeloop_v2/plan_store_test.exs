defmodule ForgeloopV2.PlanStoreTest do
  use ForgeloopV2.TestSupport

  test "parses checklist items with section and indentation metadata" do
    repo =
      create_repo_fixture!(
        plan_content: """
        # Forgeloop Plan

        ## Phase 1
        - [ ] Ship UI shell
          - [ ] Keep nested parser out of build detection
        - [x] Land events view

        ## Phase 2
        - [X] Close docs gap
        """
      )

    config = config_for!(repo.repo_root)

    assert {:ok, items} = PlanStore.read(config)

    assert [
             %PlanStore.Item{section: "Phase 1", text: "Ship UI shell", depth: 0, status: :pending},
             %PlanStore.Item{
               section: "Phase 1",
               text: "Keep nested parser out of build detection",
               depth: 2,
               status: :pending
             },
             %PlanStore.Item{section: "Phase 1", text: "Land events view", depth: 0, status: :completed},
             %PlanStore.Item{section: "Phase 2", text: "Close docs gap", depth: 0, status: :completed}
           ] = items

    assert {:ok, backlog} = PlanStore.summary(config)
    assert backlog.exists?
    assert backlog.source.kind == :implementation_plan
    assert backlog.source.label == "IMPLEMENTATION_PLAN.md"
    assert backlog.source.path == config.plan_file
    assert backlog.source.canonical?
    assert backlog.source.phase == "phase1"
    assert backlog.needs_build?
    assert length(backlog.items) == 2
  end

  test "needs build when a top-level unchecked item exists" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ] Build repo-local ui shell
          - [x] Reuse event reader
        """
      )

    config = config_for!(repo.repo_root)

    assert PlanStore.needs_build?(config)
    assert [%PlanStore.Item{text: "Build repo-local ui shell"}] = PlanStore.pending_items(config)
  end

  test "treats blank unchecked checklist placeholders as pending top-level work" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [ ]
        """
      )

    config = config_for!(repo.repo_root)

    assert PlanStore.needs_build?(config)
    assert [%PlanStore.Item{text: "", depth: 0, status: :pending}] = PlanStore.pending_items(config)
  end

  test "does not need build when only nested unchecked items remain" do
    repo =
      create_repo_fixture!(
        plan_content: """
        ## Phase 1
        - [x] Build repo-local ui shell
          - [ ] Follow-up polish
        """
      )

    config = config_for!(repo.repo_root)

    refute PlanStore.needs_build?(config)
    assert [%PlanStore.Item{text: "Follow-up polish", depth: 2}] = PlanStore.pending_items(config)
  end

  test "missing plan file returns canonical backlog metadata and still fails closed for build detection" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert :missing = PlanStore.read(config)
    assert {:ok, backlog} = PlanStore.summary(config)
    refute backlog.exists?
    assert backlog.needs_build?
    assert backlog.items == []
    assert backlog.source.kind == :implementation_plan
    assert backlog.source.label == "IMPLEMENTATION_PLAN.md"
    assert backlog.source.path == config.plan_file
    assert backlog.source.canonical?
    assert backlog.source.phase == "phase1"
    assert PlanStore.needs_build?(config)
    assert [] = PlanStore.pending_items(config)
  end

  test "unreadable plan path still returns a fail-closed backlog summary" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root, plan_file: ".")

    assert {:error, :eisdir} = PlanStore.read(config)
    assert {:ok, backlog} = PlanStore.summary(config)
    assert backlog.exists?
    assert backlog.needs_build?
    assert backlog.items == []
    assert backlog.source.path == repo.repo_root
    assert PlanStore.needs_build?(config)
    assert [] = PlanStore.pending_items(config)
  end
end
