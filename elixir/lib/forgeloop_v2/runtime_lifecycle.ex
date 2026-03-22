defmodule ForgeloopV2.ActiveRuntime do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock}

  @schema_version 2
  @legacy_claim_stale_after_seconds 120

  @spec claim(Config.t(), String.t() | keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def claim(%Config{} = config, owner) when is_binary(owner),
    do: claim(config, %{owner: owner})

  def claim(%Config{} = config, attrs) when is_list(attrs),
    do: claim(config, Map.new(attrs))

  def claim(%Config{} = config, attrs) when is_map(attrs) do
    File.mkdir_p!(config.v2_state_dir)

    with {:ok, result} <-
           ControlLock.with_lock(
             config,
             path(config),
             :runtime,
             [timeout_ms: config.control_lock_timeout_ms],
             fn ->
               case read_unlocked(config) do
                 :missing ->
                   persist_claim(config, build_claim(attrs, nil))

                 {:ok, current} ->
                   cond do
                     status_for_claim(config, current).reclaimable? ->
                       persist_claim(config, build_claim(attrs, nil))

                     same_process_claim?(current, attrs) ->
                       persist_claim(config, build_claim(attrs, current))

                     true ->
                       {:error, {:active_runtime_owned_by, current}}
                   end

                 {:error, reason} ->
                   {:error, invalid_claim_reason(config, reason)}
               end
             end
           ) do
      result
    end
  end

  @spec release(Config.t(), String.t()) :: :ok | {:error, term()}
  def release(%Config{} = config, claim_id) when is_binary(claim_id) and claim_id != "" do
    with {:ok, result} <-
           ControlLock.with_lock(
             config,
             path(config),
             :runtime,
             [timeout_ms: config.control_lock_timeout_ms],
             fn ->
               case read_unlocked(config) do
                 :missing ->
                   :ok

                 {:ok, %{"claim_id" => ^claim_id}} ->
                   case File.rm(path(config)) do
                     :ok -> :ok
                     {:error, :enoent} -> :ok
                     {:error, reason} -> {:error, reason}
                   end

                 {:ok, current} ->
                   {:error, {:active_runtime_claim_mismatch, current}}

                 {:error, reason} ->
                   {:error, invalid_claim_reason(config, reason)}
               end
             end
           ) do
      result
    end
  end

  def release(%Config{}, _claim_id), do: :ok

  @spec read(Config.t()) :: {:ok, map()} | :missing | {:error, term()}
  def read(%Config{} = config) do
    case read_unlocked(config) do
      {:error, reason} -> {:error, invalid_claim_reason(config, reason)}
      other -> other
    end
  end

  @spec status(Config.t()) :: {:ok, map()}
  def status(%Config{} = config) do
    case read_unlocked(config) do
      :missing ->
        {:ok, status_payload(nil, status_for_claim(config, nil), "missing", nil)}

      {:ok, claim} ->
        status = status_for_claim(config, claim)
        {:ok, status_payload(claim, status, status_state(status), nil)}

      {:error, reason} ->
        error = invalid_claim_reason(config, reason)
        {:ok, status_payload(nil, status_for_claim(config, nil), "error", inspect(error))}
    end
  end

  @spec path(Config.t()) :: Path.t()
  def path(%Config{} = config), do: Path.join(config.v2_state_dir, "active-runtime.json")

  defp persist_claim(%Config{} = config, claim) do
    body = Jason.encode!(claim, pretty: true) <> "\n"

    case ControlLock.atomic_write(config, path(config), :runtime, body) do
      :ok -> {:ok, claim}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_claim(attrs, current) do
    now = timestamp()

    owner = claim_attr(attrs, :owner, "elixir")

    %{
      "schema_version" => @schema_version,
      "claim_id" => current_claim_id(current) || generate_claim_id(),
      "owner" => owner,
      "surface" => claim_attr(attrs, :surface, "unknown"),
      "mode" => claim_attr(attrs, :mode, "unknown"),
      "branch" => claim_attr(attrs, :branch, ""),
      "pid" => claim_pid(attrs),
      "process_pid" => claim_process_pid(attrs, owner, current),
      "host" => claim_host(attrs),
      "started_at" => current_started_at(current) || now,
      "updated_at" => now
    }
  end

  defp current_claim_id(%{"claim_id" => claim_id}) when is_binary(claim_id) and claim_id != "",
    do: claim_id

  defp current_claim_id(_), do: nil

  defp current_started_at(%{"started_at" => started_at})
       when is_binary(started_at) and started_at != "",
       do: started_at

  defp current_started_at(_), do: nil

  defp claim_attr(attrs, key, default) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key), default))
    |> normalize_string(default)
  end

  defp claim_pid(attrs) do
    attrs
    |> Map.get(:pid, Map.get(attrs, "pid", os_pid()))
    |> normalize_pid()
  end

  defp claim_host(attrs) do
    attrs
    |> Map.get(:host, Map.get(attrs, "host", host_name()))
    |> normalize_string(host_name())
  end

  defp claim_process_pid(attrs, "elixir", current) do
    attrs
    |> Map.get(
      :process_pid,
      Map.get(attrs, "process_pid", current_process_pid(current) || current_process_pid())
    )
    |> normalize_optional_string()
  end

  defp claim_process_pid(_attrs, _owner, _current), do: nil

  defp normalize_string(value, default)
  defp normalize_string(value, _default) when is_binary(value) and value != "", do: value
  defp normalize_string(nil, default), do: default

  defp normalize_string(value, default),
    do: if(to_string(value) == "", do: default, else: to_string(value))

  defp normalize_pid(pid) when is_integer(pid) and pid > 0, do: pid

  defp normalize_pid(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_pid(_), do: nil

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(value) when is_binary(value), do: nil
  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp same_process_claim?(%{} = current, attrs) do
    owner = claim_attr(attrs, :owner, "elixir")

    cond do
      owner == "elixir" ->
        Map.get(current, "owner") == owner and
          current_process_pid(current) == current_process_pid() and
          current_process_pid() != nil

      true ->
        current_owner = Map.get(current, "owner")
        current_pid = normalize_pid(Map.get(current, "pid"))
        current_host = Map.get(current, "host")

        current_owner == owner and current_pid == os_pid() and current_pid != nil and
          current_host == host_name()
    end
  end

  defp same_process_claim?(_, _), do: false

  defp status_payload(claim, status, state, error) do
    %{
      current: claim,
      live?: status.live?,
      stale?: status.stale?,
      reclaimable?: status.reclaimable?,
      legacy?: status.legacy?,
      state: state,
      error: error
    }
  end

  defp status_state(%{live?: true}), do: "live"
  defp status_state(%{reclaimable?: true}), do: "reclaimable"
  defp status_state(_status), do: "missing"

  defp status_for_claim(_config, nil),
    do: %{live?: false, stale?: false, reclaimable?: false, legacy?: false}

  defp status_for_claim(_config, %{} = claim) do
    cond do
      legacy_claim?(claim) and legacy_claim_stale?(claim) ->
        %{live?: false, stale?: true, reclaimable?: true, legacy?: true}

      legacy_claim?(claim) ->
        %{live?: true, stale?: false, reclaimable?: false, legacy?: true}

      Map.get(claim, "owner") == "elixir" and claim_process_alive?(claim) ->
        %{live?: true, stale?: false, reclaimable?: false, legacy?: false}

      Map.get(claim, "owner") == "elixir" and not is_nil(current_process_pid(claim)) ->
        %{live?: false, stale?: true, reclaimable?: true, legacy?: false}

      same_host?(claim) and claim_pid_alive?(claim) ->
        %{live?: true, stale?: false, reclaimable?: false, legacy?: false}

      same_host?(claim) ->
        %{live?: false, stale?: true, reclaimable?: true, legacy?: false}

      true ->
        %{live?: true, stale?: false, reclaimable?: false, legacy?: false}
    end
  end

  defp legacy_claim?(%{"schema_version" => @schema_version}), do: false

  defp legacy_claim?(%{"claim_id" => claim_id}) when is_binary(claim_id) and claim_id != "",
    do: false

  defp legacy_claim?(%{"owner" => owner}) when is_binary(owner) and owner != "", do: true
  defp legacy_claim?(_), do: false

  defp legacy_claim_stale?(%{"updated_at" => updated_at}) when is_binary(updated_at) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.diff(DateTime.utc_now(), at, :second) > @legacy_claim_stale_after_seconds
    else
      _ -> true
    end
  end

  defp legacy_claim_stale?(_claim), do: false

  defp same_host?(%{"host" => host}) when is_binary(host) and host != "",
    do: host == host_name()

  defp same_host?(_), do: false

  defp claim_pid_alive?(%{"pid" => pid}) do
    case normalize_pid(pid) do
      value when is_integer(value) -> pid_alive?(value)
      _ -> false
    end
  end

  defp claim_pid_alive?(_), do: false

  defp claim_process_alive?(claim) do
    case current_process_pid(claim) do
      nil ->
        false

      pid_text ->
        try do
          pid_text
          |> String.to_charlist()
          |> :erlang.list_to_pid()
          |> Process.alive?()
        rescue
          _ -> false
        end
    end
  end

  defp current_process_pid(%{"process_pid" => pid_text})
       when is_binary(pid_text) and pid_text != "",
       do: pid_text

  defp current_process_pid(_claim), do: nil

  defp current_process_pid do
    self()
    |> inspect()
    |> normalize_optional_string()
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp pid_alive?(_), do: false

  defp read_unlocked(%Config{} = config) do
    case File.read(path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, payload} -> {:error, {:invalid_active_runtime_payload, payload}}
          {:error, reason} -> {:error, {:invalid_active_runtime_json, reason}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:active_runtime_read_failed, reason}}
    end
  end

  defp invalid_claim_reason(%Config{} = config, reason) do
    {:invalid_active_runtime_claim, path(config), reason}
  end

  defp generate_claim_id do
    "rt-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp os_pid do
    System.pid()
    |> normalize_pid()
  end

  defp host_name do
    case :inet.gethostname() do
      {:ok, hostname} ->
        hostname
        |> to_string()
        |> String.downcase()
        |> String.split(".")
        |> List.first()
        |> case do
          nil -> "unknown"
          "" -> "unknown"
          value -> value
        end

      _ ->
        "unknown"
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end

defmodule ForgeloopV2.RuntimeRecovery do
  @moduledoc false

  @type recovery_kind :: :blocked | :paused | :awaiting_human_cleared

  @spec evaluate(String.t() | nil, [String.t()], keyword()) ::
          :no_recovery | {:recover, recovery_kind()}
  def evaluate(runtime_status, unanswered_question_ids, opts \\ []) do
    allow_blocked? = Keyword.get(opts, :allow_blocked?, false)

    cond do
      runtime_status == "paused" ->
        {:recover, :paused}

      runtime_status == "awaiting-human" and unanswered_question_ids == [] ->
        {:recover, :awaiting_human_cleared}

      runtime_status == "blocked" and allow_blocked? ->
        {:recover, :blocked}

      true ->
        :no_recovery
    end
  end
end

defmodule ForgeloopV2.RuntimeLifecycle do
  @moduledoc false

  alias ForgeloopV2.{Config, Events, RuntimeStateStore}

  @transition_specs %{
    loop_started: %{
      status: "running",
      writers: [:loop, :daemon, :babysitter],
      allowed_previous: :any
    },
    failure_blocked: %{
      status: "blocked",
      transition: "blocked",
      writers: [:loop, :daemon, :babysitter],
      allowed_previous: :any
    },
    human_escalated: %{
      status: "awaiting-human",
      transition: "escalated",
      writers: [:escalation],
      allowed_previous: :any
    },
    paused_by_operator: %{
      status: "paused",
      transition: "paused",
      writers: [:daemon, :babysitter, :service],
      allowed_previous: :any
    },
    recovered: %{
      status: "recovered",
      transition: "resuming",
      writers: [:daemon, :loop, :babysitter],
      allowed_previous: ["paused", "awaiting-human", "blocked"]
    },
    loop_completed: %{
      status: "idle",
      transition: "completed",
      writers: [:loop, :daemon, :babysitter],
      allowed_previous: ["running", "recovered", "blocked"]
    },
    daemon_idle: %{
      status: "idle",
      transition: "idle",
      writers: [:daemon],
      allowed_previous: :any
    }
  }

  @spec transition_table() :: map()
  def transition_table, do: @transition_specs

  @spec transition(Config.t(), atom(), atom(), map()) ::
          {:ok, ForgeloopV2.RuntimeState.t()} | {:error, term()}
  def transition(%Config{} = config, action, writer, attrs \\ %{}) when is_map(attrs) do
    with {:ok, spec} <- fetch_spec(action, attrs),
         :ok <- validate_writer(spec, writer),
         :ok <- validate_previous(spec, RuntimeStateStore.status(config)) do
      payload =
        attrs
        |> Map.put_new(:status, spec.status)
        |> Map.put_new(:transition, transition_for(spec, attrs))
        |> Map.put_new(:surface, Atom.to_string(writer))
        |> Map.put_new(:mode, "unknown")
        |> Map.put_new(:requested_action, "")
        |> Map.put_new(:branch, "")

      case RuntimeStateStore.write(config, payload) do
        {:ok, state} ->
          :ok =
            Events.emit(config, event_type(action), %{
              "action" => Atom.to_string(action),
              "status" => state.status,
              "transition" => state.transition,
              "surface" => state.surface,
              "mode" => state.mode,
              "requested_action" => state.requested_action,
              "branch" => state.branch,
              "reason" => state.reason
            })

          {:ok, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_spec(:loop_started, attrs) do
    case Map.get(attrs, :mode, Map.get(attrs, "mode", "")) do
      "plan" ->
        {:ok, Map.put(@transition_specs.loop_started, :transition, "planning")}

      "build" ->
        {:ok, Map.put(@transition_specs.loop_started, :transition, "building")}

      other when is_binary(other) and other != "" ->
        {:ok, Map.put(@transition_specs.loop_started, :transition, other)}

      _ ->
        {:error, {:invalid_runtime_mode, :loop_started}}
    end
  end

  defp fetch_spec(action, _attrs) do
    case Map.fetch(@transition_specs, action) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_runtime_action, action}}
    end
  end

  defp validate_writer(spec, writer) do
    if writer in spec.writers do
      :ok
    else
      {:error, {:invalid_runtime_writer, writer, spec.writers}}
    end
  end

  defp validate_previous(%{allowed_previous: :any}, _previous), do: :ok

  defp validate_previous(spec, previous) do
    if previous in spec.allowed_previous do
      :ok
    else
      {:error, {:invalid_runtime_transition, previous, spec.status, transition_for(spec, %{})}}
    end
  end

  defp transition_for(spec, attrs) do
    Map.get(spec, :transition) ||
      Map.get(attrs, :transition, Map.get(attrs, "transition", spec.status))
  end

  defp event_type(:paused_by_operator), do: "pause_detected"
  defp event_type(:recovered), do: "recovery_started"
  defp event_type(:loop_started), do: "loop_started"
  defp event_type(:loop_completed), do: "loop_completed"
  defp event_type(:failure_blocked), do: "loop_failed"
  defp event_type(_action), do: "runtime_transition"
end
