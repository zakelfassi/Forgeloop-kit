defmodule ForgeloopV2.DaemonStateStore do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock}

  @defaults %{
    "blocked_iteration_count" => 0,
    "last_blocker_hash" => "",
    "daily_iteration_count" => 0,
    "daily_iteration_date" => "",
    "stall_cycle_count" => 0,
    "last_head_hash" => ""
  }

  @spec read(Config.t()) :: {:ok, map()} | {:error, term()}
  def read(%Config{} = config) do
    File.mkdir_p!(config.v2_state_dir)

    case File.read(path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, normalize(payload)}
          _ -> {:ok, @defaults}
        end

      {:error, :enoent} ->
        {:ok, @defaults}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update(Config.t(), (map() -> map() | {:ok, map()} | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def update(%Config{} = config, fun) when is_function(fun, 1) do
    with :ok <- File.mkdir_p(config.v2_state_dir),
         {:ok, result} <-
           ControlLock.with_lock(config, path(config), :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
             with {:ok, state} <- read(config),
                  {:ok, next_state} <- normalize_update_result(fun.(state)),
                  :ok <- write(config, next_state) do
               {:ok, normalize(next_state)}
             end
           end) do
      result
    end
  end

  @spec patch(Config.t(), map()) :: {:ok, map()} | {:error, term()}
  def patch(%Config{} = config, attrs) when is_map(attrs) do
    update(config, fn state -> Map.merge(state, attrs) end)
  end

  @spec reset_daily_if_needed(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reset_daily_if_needed(%Config{} = config, today) when is_binary(today) do
    update(config, fn state ->
      if Map.get(state, "daily_iteration_date") == today do
        state
      else
        state
        |> Map.put("daily_iteration_count", 0)
        |> Map.put("daily_iteration_date", today)
      end
    end)
  end

  @spec increment_daily_iteration(Config.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def increment_daily_iteration(%Config{} = config, today) when is_binary(today) do
    with {:ok, state} <-
           update(config, fn state ->
             state =
               if Map.get(state, "daily_iteration_date") == today do
                 state
               else
                 state
                 |> Map.put("daily_iteration_count", 0)
                 |> Map.put("daily_iteration_date", today)
               end

             Map.update(state, "daily_iteration_count", 1, &(&1 + 1))
           end) do
      {:ok, Map.get(state, "daily_iteration_count", 0)}
    end
  end

  @spec record_stall_head(Config.t(), String.t()) :: {:ok, %{count: non_neg_integer(), changed?: boolean()}} | {:error, term()}
  def record_stall_head(%Config{} = config, head_hash) when is_binary(head_hash) do
    with {:ok, state} <-
           update(config, fn state ->
             if Map.get(state, "last_head_hash", "") == head_hash do
               Map.update(state, "stall_cycle_count", 1, &(&1 + 1))
             else
               state
               |> Map.put("last_head_hash", head_hash)
               |> Map.put("stall_cycle_count", 0)
             end
           end) do
      {:ok,
       %{
         count: Map.get(state, "stall_cycle_count", 0),
         changed?: Map.get(state, "last_head_hash", "") != head_hash or Map.get(state, "stall_cycle_count", 0) == 0
       }}
    end
  end

  @spec reset_stall(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reset_stall(%Config{} = config, head_hash \\ "") when is_binary(head_hash) do
    patch(config, %{"stall_cycle_count" => 0, "last_head_hash" => head_hash})
  end

  @spec path(Config.t()) :: Path.t()
  def path(%Config{} = config), do: Path.join(config.v2_state_dir, "daemon-state.json")

  defp write(%Config{} = config, state) do
    ControlLock.atomic_write(config, path(config), :runtime, Jason.encode!(normalize(state), pretty: true) <> "\n")
  end

  defp normalize(payload) when is_map(payload) do
    payload = Map.new(payload, fn {key, value} -> {to_string(key), value} end)

    Map.merge(@defaults, payload, fn
      key, _default, value when key in ["blocked_iteration_count", "daily_iteration_count", "stall_cycle_count"] ->
        normalize_non_negative_int(value)

      _key, _default, value when is_binary(value) ->
        value

      _key, _default, value ->
        to_string(value)
    end)
  end

  defp normalize_update_result({:ok, state}) when is_map(state), do: {:ok, state}
  defp normalize_update_result({:error, _reason} = error), do: error
  defp normalize_update_result(state) when is_map(state), do: {:ok, state}
  defp normalize_update_result(other), do: {:error, {:invalid_daemon_state_update, other}}

  defp normalize_non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp normalize_non_negative_int(_value), do: 0
end
