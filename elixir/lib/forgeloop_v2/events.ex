defmodule ForgeloopV2.Events do
  @moduledoc false

  alias ForgeloopV2.Config

  @allowed_event_types ~w(
    daemon_tick
    runtime_transition
    loop_started
    loop_completed
    loop_failed
    failure_recorded
    failure_escalated
    blocker_tracking
    blocker_escalated
    provider_attempted
    provider_failed_over
    pause_detected
    recovery_started
    worktree_prepared
    worktree_cleaned
    babysitter_started
    babysitter_heartbeat
    babysitter_stopped
    babysitter_completed
    babysitter_failed
  )

  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: @allowed_event_types

  @spec event_log_path(Config.t()) :: Path.t()
  def event_log_path(%Config{} = config), do: Path.join(config.v2_state_dir, "events.log")

  @spec emit(Config.t(), atom() | binary(), map()) :: :ok
  def emit(%Config{} = config, event_type, payload \\ %{}) when is_map(payload) do
    normalized_type = normalize_type(event_type)

    entry =
      payload
      |> Map.put_new("event_type", normalized_type)
      |> Map.put_new("recorded_at", timestamp())

    with :ok <- File.mkdir_p(config.v2_state_dir),
         {:ok, encoded} <- Jason.encode(entry),
         :ok <- File.write(event_log_path(config), encoded <> "\n", [:append]) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec read_all(Config.t()) :: [map()]
  def read_all(%Config{} = config) do
    case File.read(event_log_path(config)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, payload} when is_map(payload) -> [payload | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp normalize_type(event_type) when is_atom(event_type), do: normalize_type(Atom.to_string(event_type))

  defp normalize_type(event_type) when is_binary(event_type) do
    if event_type in @allowed_event_types, do: event_type, else: "runtime_transition"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
