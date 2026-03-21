defmodule ForgeloopV2.ProviderHealthTest do
  use ForgeloopV2.TestSupport

  test "derives provider state and latest provider events" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root)
    now = System.os_time(:second) + 120

    :ok = ForgeloopV2.LLM.StateStore.write(config, %{
      "claude_auth_failed" => true,
      "codex_rate_limited_until" => now
    })

    :ok = Events.emit(config, :provider_attempted, %{"provider" => "claude", "recorded_at" => "2026-03-21T10:00:00Z"})
    :ok = Events.emit(config, :provider_failed_over, %{"from_provider" => "claude", "reason" => "auth_error", "recorded_at" => "2026-03-21T10:01:00Z"})
    :ok = Events.emit(config, :provider_attempted, %{"provider" => "codex", "recorded_at" => "2026-03-21T10:02:00Z"})

    payload = ProviderHealth.read(config)
    assert payload["failover_enabled"] == true

    claude = Enum.find(payload["providers"], &(&1["name"] == "claude"))
    codex = Enum.find(payload["providers"], &(&1["name"] == "codex"))

    assert claude["status"] == "auth_failed"
    assert claude["last_attempted_at"] == "2026-03-21T10:00:00Z"
    assert claude["last_failover_at"] == "2026-03-21T10:01:00Z"
    assert claude["last_failover_reason"] == "auth_error"

    assert codex["status"] == "rate_limited"
    assert codex["last_attempted_at"] == "2026-03-21T10:02:00Z"
    assert is_binary(codex["rate_limited_until_iso"])
  end
end
