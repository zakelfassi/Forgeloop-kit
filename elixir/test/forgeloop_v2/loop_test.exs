defmodule ForgeloopV2.LoopTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.Loop

  test "direct loop run emits recovery for paused state before starting work" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    config = config_for!(repo.repo_root)

    {:ok, _} =
      RuntimeLifecycle.transition(config, :paused_by_operator, :daemon, %{
        surface: "daemon",
        mode: "daemon",
        reason: "Paused",
        requested_action: "",
        branch: "main"
      })

    assert {:ok, %{mode: :build}} =
             Loop.run(:build, config,
               driver: ForgeloopV2.WorkDrivers.Noop,
               driver_opts: [build: {:ok, %{mode: :build}}],
               branch: "main"
             )

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert "recovery_started" in event_types

    assert Enum.find_index(event_types, &(&1 == "recovery_started")) <
             Enum.find_index(event_types, &(&1 == "loop_started"))
  end

  test "direct loop run emits recovery for cleared awaiting-human state before starting work" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    config = config_for!(repo.repo_root)

    {:ok, _} =
      RuntimeLifecycle.transition(config, :human_escalated, :escalation, %{
        surface: "loop",
        mode: "build",
        reason: "Need operator input",
        requested_action: "issue",
        branch: "main"
      })

    ControlFiles.consume_flag(config, "PAUSE")
    File.write!(config.questions_file, "")

    assert {:ok, %{mode: :build}} =
             Loop.run(:build, config,
               driver: ForgeloopV2.WorkDrivers.Noop,
               driver_opts: [build: {:ok, %{mode: :build}}],
               branch: "main"
             )

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert "recovery_started" in event_types

    assert Enum.find_index(event_types, &(&1 == "recovery_started")) <
             Enum.find_index(event_types, &(&1 == "loop_started"))
  end

  test "direct loop run does not emit recovery for awaiting-human while questions remain" do
    repo =
      create_repo_fixture!(
        plan_content: "- [ ] pending task\n",
        questions: """
        ## Q-123 (2026-03-05 00:00:00)
        **Category**: blocked
        **Question**: Human input required
        **Status**: ⏳ Awaiting response

        **Answer**:
        """
      )

    config = config_for!(repo.repo_root)

    {:ok, _} =
      RuntimeLifecycle.transition(config, :human_escalated, :escalation, %{
        surface: "loop",
        mode: "build",
        reason: "Need operator input",
        requested_action: "issue",
        branch: "main"
      })

    ControlFiles.consume_flag(config, "PAUSE")

    assert {:ok, %{mode: :build}} =
             Loop.run(:build, config,
               driver: ForgeloopV2.WorkDrivers.Noop,
               driver_opts: [build: {:ok, %{mode: :build}}],
               branch: "main"
             )

    event_types = Events.read_all(config) |> Enum.map(& &1["event_type"])
    assert Enum.count(event_types, &(&1 == "recovery_started")) == 0
    assert "loop_started" in event_types
  end

  test "direct loop run releases the active runtime claim on success" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    config = config_for!(repo.repo_root)

    assert {:ok, %{mode: :build}} =
             Loop.run(:build, config,
               driver: ForgeloopV2.WorkDrivers.Noop,
               driver_opts: [build: {:ok, %{mode: :build}}],
               branch: "main"
             )

    assert :missing = ActiveRuntime.read(config)
  end

  test "direct loop run rejects a live conflicting runtime owner before loop start" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    config = config_for!(repo.repo_root)
    claim = write_runtime_claim!(config, owner: "bash", mode: "daemon")

    assert {:error, {:active_runtime_owned_by, current}} =
             Loop.run(:build, config,
               driver: ForgeloopV2.WorkDrivers.Noop,
               driver_opts: [build: {:ok, %{mode: :build}}],
               branch: "main"
             )

    assert current["claim_id"] == claim["claim_id"]
    refute Enum.any?(Events.read_all(config), &(&1["event_type"] == "loop_started"))
  end
end
