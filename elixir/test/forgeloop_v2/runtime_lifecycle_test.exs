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

    assert {:error, {:invalid_runtime_writer, :loop, [:daemon, :babysitter, :service]}} =
             RuntimeLifecycle.transition(config, :paused_by_operator, :loop, %{
               surface: "loop",
               mode: "build",
               reason: "Bad writer",
               branch: "main"
             })

    assert {:ok, paused_state} =
             RuntimeLifecycle.transition(config, :paused_by_operator, :service, %{
               surface: "service",
               mode: "service",
               reason: "Paused via loopback control plane",
               branch: "main"
             })

    assert paused_state.status == "paused"
    assert paused_state.surface == "service"

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

  test "active runtime claims reject conflicting live owner and release matching claim ids" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    bash_claim = write_runtime_claim!(config, owner: "bash", mode: "daemon")

    assert {:error, {:active_runtime_owned_by, current}} =
             ActiveRuntime.claim(config, owner: "elixir", surface: "daemon", mode: "build")

    assert current["owner"] == "bash"
    assert current["claim_id"] == bash_claim["claim_id"]

    assert {:error, {:active_runtime_claim_mismatch, current}} =
             ActiveRuntime.release(config, "rt-other")

    assert current["claim_id"] == bash_claim["claim_id"]
    assert :ok = ActiveRuntime.release(config, bash_claim["claim_id"])
    assert :missing = ActiveRuntime.read(config)
  end

  test "recent legacy runtime claims block conservatively until stale" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    write_legacy_runtime_claim!(config)

    assert {:ok,
            %{
              legacy?: true,
              reclaimable?: false,
              live?: true,
              stale?: false,
              state: "live",
              error: nil
            }} =
             ActiveRuntime.status(config)

    assert {:error, {:active_runtime_owned_by, current}} =
             ActiveRuntime.claim(config, owner: "elixir", surface: "loop", mode: "build")

    assert current["owner"] == "bash"
  end

  test "stale legacy runtime claims are reclaimable" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    stale_timestamp =
      DateTime.utc_now()
      |> DateTime.add(-300, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    write_legacy_runtime_claim!(config, "bash", stale_timestamp)

    assert {:ok,
            %{
              legacy?: true,
              reclaimable?: true,
              live?: false,
              stale?: true,
              state: "reclaimable",
              error: nil
            }} =
             ActiveRuntime.status(config)

    assert {:ok, claim} =
             ActiveRuntime.claim(config, owner: "elixir", surface: "loop", mode: "build")

    assert claim["schema_version"] == 2
    assert claim["owner"] == "elixir"
    assert claim["claim_id"] != nil
  end

  test "structured stale runtime claims are reclaimable" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)

    write_runtime_claim_payload!(config, %{
      "schema_version" => 2,
      "claim_id" => "rt-stale-structured",
      "owner" => "bash",
      "surface" => "daemon",
      "mode" => "build",
      "branch" => config.default_branch,
      "pid" => 999_999,
      "process_pid" => nil,
      "host" => local_host_name!(),
      "started_at" => ago_iso!(300),
      "updated_at" => ago_iso!(300)
    })

    assert {:ok,
            %{
              legacy?: false,
              reclaimable?: true,
              live?: false,
              stale?: true,
              state: "reclaimable",
              error: nil
            }} =
             ActiveRuntime.status(config)

    assert {:ok, claim} =
             ActiveRuntime.claim(config, owner: "elixir", surface: "loop", mode: "build")

    assert claim["schema_version"] == 2
    assert claim["owner"] == "elixir"
    assert is_binary(claim["claim_id"])
  end

  test "malformed runtime claims surface explicit error state and block new claims" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    write_raw_runtime_claim!(config, "{not-json\n")

    assert {:error, {:invalid_active_runtime_claim, path, _reason}} = ActiveRuntime.read(config)
    assert path == ActiveRuntime.path(config)

    assert {:ok, %{state: "error", error: error, live?: false, reclaimable?: false, current: nil}} =
             ActiveRuntime.status(config)

    assert error =~ "invalid_active_runtime_claim"

    assert {:error, {:invalid_active_runtime_claim, ^path, _reason}} =
             ActiveRuntime.claim(config, owner: "elixir", surface: "loop", mode: "build")
  end
end
