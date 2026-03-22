defmodule ForgeloopV2.ProviderHealth do
  @moduledoc false

  alias ForgeloopV2.{Config, Events, LLM.StateStore}

  @providers ["claude", "codex"]

  @spec read(Config.t()) :: map()
  def read(%Config{} = config) do
    state = StateStore.read(config)
    events = Events.read_all(config)

    %{
      "failover_enabled" => config.enable_failover,
      "providers" => Enum.map(@providers, &provider_summary(&1, config, state, events))
    }
  end

  defp provider_summary(name, %Config{} = config, state, events) do
    auth_failed = Map.get(state, "#{name}_auth_failed", false)
    rate_limited_until = normalize_rate_limit(Map.get(state, "#{name}_rate_limited_until", 0))
    last_attempted_at = last_attempted_at(events, name)
    {last_failover_at, last_failover_reason} = last_failover(events, name)

    %{
      "name" => name,
      "disabled" => disabled?(config, name),
      "status" => status_for(config, name, auth_failed, rate_limited_until),
      "auth_failed" => auth_failed,
      "rate_limited_until" => rate_limited_until,
      "rate_limited_until_iso" => iso_timestamp(rate_limited_until),
      "last_attempted_at" => last_attempted_at,
      "last_failover_at" => last_failover_at,
      "last_failover_reason" => last_failover_reason
    }
  end

  defp disabled?(config, "claude"), do: config.disable_claude
  defp disabled?(config, "codex"), do: config.disable_codex

  defp status_for(config, name, auth_failed, rate_limited_until) do
    cond do
      disabled?(config, name) -> "disabled"
      is_integer(rate_limited_until) -> "rate_limited"
      auth_failed -> "auth_failed"
      true -> "available"
    end
  end

  defp normalize_rate_limit(value) when is_integer(value) do
    if value > System.os_time(:second), do: value, else: nil
  end

  defp normalize_rate_limit(_), do: nil

  defp iso_timestamp(nil), do: nil

  defp iso_timestamp(unix_seconds) when is_integer(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp last_attempted_at(events, name) do
    Enum.find_value(Enum.reverse(events), fn
      %{"provider" => ^name} = event ->
        if event_code(event) == "provider_attempted", do: event_timestamp(event), else: nil

      _ ->
        nil
    end)
  end

  defp last_failover(events, name) do
    Enum.find_value(Enum.reverse(events), {nil, nil}, fn
      %{"from_provider" => ^name} = event ->
        if event_code(event) == "provider_failed_over" do
          {event_timestamp(event), Map.get(event, "reason")}
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp event_code(event), do: Map.get(event, "event_code") || Map.get(event, "event_type")
  defp event_timestamp(event), do: Map.get(event, "occurred_at") || Map.get(event, "recorded_at")
end
