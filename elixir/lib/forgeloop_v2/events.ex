defmodule ForgeloopV2.Events do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock}

  @known_event_types ~w(
    daemon_tick
    daemon_stall_check_failed
    daemon_deploy_started
    daemon_deploy_completed
    daemon_deploy_failed
    daemon_ingest_logs_started
    daemon_ingest_logs_completed
    daemon_ingest_logs_failed
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
    control_plane_started
    control_plane_stopped
    service_http_started
    service_http_stopped
    operator_action
  )

  @default_limit 50
  @max_limit 500
  @registry ForgeloopV2.EventsRegistry

  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: @known_event_types

  @spec event_log_path(Config.t()) :: Path.t()
  def event_log_path(%Config{} = config), do: Path.join(config.v2_state_dir, "events.log")

  @spec emit(Config.t(), atom() | binary(), map()) :: :ok
  def emit(%Config{} = config, event_type, payload \\ %{}) when is_map(payload) do
    path = event_log_path(config)
    entry = build_entry(event_type, payload)

    with :ok <- File.mkdir_p(config.v2_state_dir),
         {:ok, :ok} <-
           ControlLock.with_lock(config, path, :runtime, [timeout_ms: config.control_lock_timeout_ms], fn ->
             append_entry(path, entry)
           end) do
      notify_subscribers(path, entry)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec read_all(Config.t()) :: [map()]
  def read_all(%Config{} = config) do
    config
    |> read_entries()
    |> Enum.map(& &1.event)
  end

  @spec tail(Config.t(), keyword()) :: {:ok, %{items: [map()], meta: map()}}
  def tail(%Config{} = config, opts \\ []) do
    entries = read_entries(config)
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    items = Enum.take(entries, -limit) |> Enum.map(& &1.event)

    {:ok,
     %{
       items: items,
       meta: %{
         latest_event_id: latest_event_id(entries),
         returned_count: length(items),
         limit: limit,
         truncated?: length(entries) > length(items)
       }
     }}
  end

  @spec replay(Config.t(), keyword()) :: {:ok, %{items: [map()], meta: map()}}
  def replay(%Config{} = config, opts \\ []) do
    entries = read_entries(config)
    after_cursor = normalize_cursor(Keyword.get(opts, :after))
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))

    {items, cursor_found?, truncated?} =
      case after_cursor do
        nil -> {[], false, false}
        cursor -> replay_items(entries, cursor, limit)
      end

    {:ok,
     %{
       items: items,
       meta: %{
         after: after_cursor,
         latest_event_id: latest_event_id(entries),
         returned_count: length(items),
         limit: limit,
         cursor_found?: cursor_found?,
         truncated?: truncated?
       }
     }}
  end

  @spec subscribe(Config.t()) :: :ok
  def subscribe(%Config{} = config) do
    case Registry.register(@registry, event_log_path(config), nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec unsubscribe(Config.t()) :: :ok
  def unsubscribe(%Config{} = config) do
    Registry.unregister(@registry, event_log_path(config))
    :ok
  rescue
    _ -> :ok
  end

  defp append_entry(path, entry) do
    with {:ok, encoded} <- Jason.encode(entry) do
      File.write(path, encoded <> "\n", [:append])
    end
  end

  defp build_entry(event_type, payload) do
    event_code = normalize_type(event_type)
    normalized_payload = normalize_payload_keys(payload)

    occurred_at =
      normalized_payload["occurred_at"] ||
        normalized_payload["recorded_at"] ||
        timestamp()

    normalized_payload
    |> Map.put_new("event_id", generate_event_id())
    |> Map.put("event_code", event_code)
    |> Map.put("occurred_at", occurred_at)
    |> Map.put("event_type", event_code)
    |> Map.put("recorded_at", occurred_at)
  end

  defp notify_subscribers(path, entry) do
    Registry.dispatch(@registry, path, fn registrations ->
      Enum.each(registrations, fn {pid, _value} ->
        send(pid, {:forgeloop_v2_event, path, entry})
      end)
    end)
  rescue
    _ -> :ok
  end

  defp read_entries(%Config{} = config) do
    case File.read(event_log_path(config)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {line, line_number}, acc ->
          case Jason.decode(line) do
            {:ok, payload} when is_map(payload) ->
              [%{line_number: line_number, event: normalize_event(payload, line_number, line)} | acc]

            _ ->
              acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp normalize_event(payload, line_number, raw_line) do
    event_code =
      payload["event_code"] ||
        payload["event_type"] ||
        payload[:event_code] ||
        payload[:event_type] ||
        "runtime_transition"

    occurred_at =
      payload["occurred_at"] ||
        payload["recorded_at"] ||
        payload[:occurred_at] ||
        payload[:recorded_at]

    payload
    |> normalize_payload_keys()
    |> Map.put("event_id", payload["event_id"] || payload[:event_id] || legacy_event_id(line_number, raw_line))
    |> Map.put("event_code", normalize_type(event_code))
    |> Map.put("occurred_at", occurred_at)
    |> Map.put("event_type", normalize_type(event_code))
    |> Map.put("recorded_at", occurred_at)
  end

  defp replay_items(entries, cursor, limit) do
    case Enum.split_while(entries, fn %{event: event} -> event["event_id"] != cursor end) do
      {_, []} -> {[], false, false}
      {_before, [_cursor | after_entries]} ->
        total_after = length(after_entries)
        items = Enum.take(after_entries, limit) |> Enum.map(& &1.event)
        {items, true, total_after > length(items)}
    end
  end

  defp latest_event_id([]), do: nil
  defp latest_event_id(entries), do: entries |> List.last() |> then(& &1.event["event_id"])

  defp normalize_payload_keys(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp normalize_type(event_type) when is_atom(event_type), do: normalize_type(Atom.to_string(event_type))

  defp normalize_type(event_type) when is_binary(event_type) do
    event_type
    |> String.trim()
    |> case do
      "" -> "runtime_transition"
      value ->
        if Regex.match?(~r/^[a-z0-9_:-]+$/, value) do
          value
        else
          value
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9_:-]+/, "_")
          |> String.trim("_")
          |> case do
            "" -> "runtime_transition"
            normalized -> normalized
          end
        end
    end
  end

  defp normalize_type(_event_type), do: "runtime_transition"

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} when int > 0 -> min(int, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_cursor(cursor) when is_binary(cursor) do
    case String.trim(cursor) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_cursor(_), do: nil

  defp generate_event_id do
    "evt-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp legacy_event_id(line_number, raw_line) do
    hash =
      :crypto.hash(:sha256, raw_line)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "legacy:#{line_number}:#{hash}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
