defmodule ForgeloopV2.LlmRouterTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.LLM.{Router, StateStore}

  test "auth-marker output with exit 0 fails over to alternate provider and persists auth failure" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    fake_bin = Path.join(repo.repo_root, ".fake-bin")

    write_executable!(
      Path.join(fake_bin, "claude"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "Invalid API Key"
      exit 0
      """
    )

    write_executable!(
      Path.join(fake_bin, "codex"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "codex-fallback-ok"
      exit 0
      """
    )

    result =
      with_env([{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}], fn ->
        {:ok, result} = Router.exec(:build, "hello\n", config)
        result
      end)

    assert result.provider == :codex
    assert result.output =~ "codex-fallback-ok"
    assert StateStore.read(config)["claude_auth_failed"] == true
  end

  test "rate limited preferred provider skips to alternate and both unavailable returns error" do
    repo = create_repo_fixture!()
    config = config_for!(repo.repo_root)
    fake_bin = Path.join(repo.repo_root, ".fake-bin")

    write_executable!(
      Path.join(fake_bin, "claude"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "rate limit exceeded"
      exit 1
      """
    )

    write_executable!(
      Path.join(fake_bin, "codex"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "codex-ok"
      exit 0
      """
    )

    result =
      with_env([{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}], fn ->
        {:ok, result} = Router.exec(:build, "hello\n", config)
        result
      end)

    assert result.provider == :codex
    assert result.output =~ "codex-ok"

    write_executable!(
      Path.join(fake_bin, "codex"),
      """
      #!/usr/bin/env bash
      cat >/dev/null
      echo "still rate limited"
      exit 1
      """
    )

    assert {:error, _reason} =
             with_env([{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}], fn ->
               Router.exec(:build, "hello\n", config)
             end)
  end
end
