defmodule ForgeloopV2.LLM.StateStore do
  @moduledoc false

  alias ForgeloopV2.Config

  @default %{
    "claude_auth_failed" => false,
    "codex_auth_failed" => false,
    "claude_rate_limited_until" => 0,
    "codex_rate_limited_until" => 0
  }

  @spec read(Config.t()) :: map()
  def read(%Config{} = config) do
    case File.read(path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> Map.merge(@default, payload)
          _ -> @default
        end

      _ ->
        @default
    end
  end

  @spec write(Config.t(), map()) :: :ok | {:error, term()}
  def write(%Config{} = config, payload) do
    File.mkdir_p!(config.v2_state_dir)
    File.write(path(config), Jason.encode!(Map.merge(@default, payload), pretty: true) <> "\n")
  end

  defp path(config), do: Path.join(config.v2_state_dir, "providers-state.json")
end

defmodule ForgeloopV2.LLM.ProviderResult do
  @moduledoc false
  defstruct provider: nil,
            exit_status: 0,
            output: "",
            auth_error?: false,
            rate_limited_until: nil,
            success?: false
end

defmodule ForgeloopV2.LLM.CommandRunner do
  @moduledoc false

  @spec run(binary(), [binary()], iodata()) :: {binary(), integer()}
  def run(cli, args, input) do
    shell = System.find_executable("bash") || System.find_executable("sh")

    cond do
      is_nil(System.find_executable(cli)) ->
        {"command not found: #{cli}", 127}

      is_nil(shell) ->
        {"shell not found for command execution", 127}

      true ->
        System.cmd(
          shell,
          ["-lc", ~s(printf '%s' "$FORGELOOP_V2_INPUT" | exec "$0" "$@"), cli | args],
          env: [{"FORGELOOP_V2_INPUT", IO.iodata_to_binary(input)}],
          stderr_to_stdout: true
        )
    end
  end
end

defmodule ForgeloopV2.LLM.Providers.ClaudeCli do
  @moduledoc false

  alias ForgeloopV2.{Config, LLM.ProviderResult}

  @auth_pattern ~r/(invalid_api_key|authentication_error|could not resolve authentication|anthropic_api_key|not authenticated|not logged in|invalid api key|unable to authenticate|apikeyinvalid|unauthorized|missing credentials|credentials not found|invalid credentials)/i
  @rate_limit_pattern ~r/(rate limit|too many requests|try again later|quota)/i

  @spec run(iodata(), Config.t()) :: ProviderResult.t()
  def run(input, %Config{} = config) do
    execute(:claude, config.claude_cli, config.claude_flags, input, @auth_pattern, @rate_limit_pattern)
  end

  defp execute(provider, cli, flags, input, auth_pattern, rate_limit_pattern) do
    args = String.split(flags || "", " ", trim: true)

    {output, status} = ForgeloopV2.LLM.CommandRunner.run(cli, args, input)

    auth_error? = Regex.match?(auth_pattern, output)
    rate_limited_until = if Regex.match?(rate_limit_pattern, output), do: System.os_time(:second) + 300, else: nil

    %ProviderResult{
      provider: provider,
      exit_status: status,
      output: output,
      auth_error?: auth_error?,
      rate_limited_until: rate_limited_until,
      success?: status == 0 and not auth_error? and is_nil(rate_limited_until)
    }
  end
end

defmodule ForgeloopV2.LLM.Providers.CodexCli do
  @moduledoc false

  alias ForgeloopV2.{Config, LLM.ProviderResult}

  @auth_pattern ~r/(invalid_api_key|authentication_error|openai_api_key|incorrect api key|unable to authenticate|api key not found|not logged in|unauthorized|missing credentials|credentials not found|invalid credentials)/i
  @rate_limit_pattern ~r/(rate limit|too many requests|try again later|quota)/i

  @spec run(iodata(), Config.t()) :: ProviderResult.t()
  def run(input, %Config{} = config) do
    execute(:codex, config.codex_cli, config.codex_flags, input, @auth_pattern, @rate_limit_pattern)
  end

  defp execute(provider, cli, flags, input, auth_pattern, rate_limit_pattern) do
    args = String.split(flags || "", " ", trim: true)

    {output, status} = ForgeloopV2.LLM.CommandRunner.run(cli, args, input)

    auth_error? = Regex.match?(auth_pattern, output)
    rate_limited_until = if Regex.match?(rate_limit_pattern, output), do: System.os_time(:second) + 300, else: nil

    %ProviderResult{
      provider: provider,
      exit_status: status,
      output: output,
      auth_error?: auth_error?,
      rate_limited_until: rate_limited_until,
      success?: status == 0 and not auth_error? and is_nil(rate_limited_until)
    }
  end
end

defmodule ForgeloopV2.LLM.Router do
  @moduledoc false

  alias ForgeloopV2.{Config, LLM.ProviderResult, LLM.StateStore}

  @spec exec(:plan | :review | :security | :build, iodata(), Config.t(), keyword()) ::
          {:ok, ProviderResult.t()} | {:error, term()}
  def exec(task_type, input, %Config{} = config, _opts \\ []) do
    state = StateStore.read(config)
    providers = provider_order(task_type, config)

    with {:ok, result, new_state} <- try_providers(providers, input, config, state) do
      :ok = StateStore.write(config, new_state)
      {:ok, result}
    else
      {:error, reason, new_state} ->
        :ok = StateStore.write(config, new_state)
        {:error, reason}
    end
  end

  defp try_providers([], _input, _config, state), do: {:error, :no_available_provider, state}

  defp try_providers([provider | rest], input, config, state) do
    cond do
      unavailable?(provider, config, state) ->
        try_providers(rest, input, config, state)

      true ->
        result = execute(provider, input, config)
        updated_state = update_state(state, result)

        cond do
          result.success? ->
            {:ok, result, clear_auth_flag(updated_state, provider)}

          result.auth_error? and config.enable_failover and rest != [] ->
            try_providers(rest, input, config, updated_state)

          result.rate_limited_until && config.enable_failover and rest != [] ->
            try_providers(rest, input, config, updated_state)

          result.auth_error? ->
            {:error, {:auth_failed, provider}, updated_state}

          result.rate_limited_until ->
            {:error, {:rate_limited, provider, result.rate_limited_until}, updated_state}

          true ->
            {:error, {:provider_failed, provider, result.exit_status}, updated_state}
        end
    end
  end

  defp execute(:claude, input, config), do: ForgeloopV2.LLM.Providers.ClaudeCli.run(input, config)
  defp execute(:codex, input, config), do: ForgeloopV2.LLM.Providers.CodexCli.run(input, config)

  defp provider_order(task_type, config) do
    preferred =
      case task_type do
        :plan -> config.planning_model
        :review -> config.review_model
        :security -> config.security_model
        :build -> config.build_model
      end
      |> normalize_provider()

    alternate = if preferred == :claude, do: :codex, else: :claude
    [preferred, alternate]
  end

  defp normalize_provider(value) when is_atom(value), do: value
  defp normalize_provider("claude"), do: :claude
  defp normalize_provider(_), do: :codex

  defp unavailable?(:claude, config, state) do
    config.disable_claude or future?(Map.get(state, "claude_rate_limited_until", 0))
  end

  defp unavailable?(:codex, config, state) do
    config.disable_codex or future?(Map.get(state, "codex_rate_limited_until", 0))
  end

  defp future?(value) when is_integer(value), do: value > System.os_time(:second)
  defp future?(_), do: false

  defp update_state(state, %ProviderResult{provider: :claude, auth_error?: auth, rate_limited_until: until_ts}) do
    state
    |> Map.put("claude_auth_failed", auth or Map.get(state, "claude_auth_failed", false))
    |> maybe_put("claude_rate_limited_until", until_ts)
  end

  defp update_state(state, %ProviderResult{provider: :codex, auth_error?: auth, rate_limited_until: until_ts}) do
    state
    |> Map.put("codex_auth_failed", auth or Map.get(state, "codex_auth_failed", false))
    |> maybe_put("codex_rate_limited_until", until_ts)
  end

  defp clear_auth_flag(state, :claude), do: Map.put(state, "claude_auth_failed", false)
  defp clear_auth_flag(state, :codex), do: Map.put(state, "codex_auth_failed", false)

  defp maybe_put(state, _key, nil), do: state
  defp maybe_put(state, key, value), do: Map.put(state, key, value)
end
