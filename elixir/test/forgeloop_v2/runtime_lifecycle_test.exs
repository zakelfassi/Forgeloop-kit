defmodule ForgeloopV2.RuntimeLifecycleTest do
  use ForgeloopV2.TestSupport

  test "enforces transition writers and predecessor states" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    assert {:ok, _state} =
             RuntimeLifecycle.transition(config, :loop_started, :loop, %{
               surface: "loop",
               mode: "build",
               reason: "Build run started",
               branch: "main"
             })

    assert {:error, {:invalid_runtime_writer, :loop, [:daemon]}} =
             RuntimeLifecycle.transition(config, :paused_by_operator, :loop, %{
               surface: "loop",
               mode: "build",
               reason: "Bad writer",
               branch: "main"
             })

    repo2 = create_repo_fixture!()
    config2 = config_for!(repo2.repo_root)

    assert {:error, {:invalid_runtime_transition, "", "recovered", "resuming"}} =
             RuntimeLifecycle.transition(config2, :recovered, :daemon, %{
               surface: "daemon",
               mode: "daemon",
               reason: "Cannot recover without prior pause",
               branch: "main"
             })
  end

  test "active runtime claims reject conflicting owner" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    File.mkdir_p!(config.v2_state_dir)
    File.write!(ActiveRuntime.path(config), Jason.encode!(%{"owner" => "bash"}) <> "\n")

    assert {:error, {:active_runtime_owned_by, "bash"}} = ActiveRuntime.claim(config, "elixir")
  end
end
