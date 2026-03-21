defmodule ForgeloopV2.ActiveRuntime do
  @moduledoc false

  alias ForgeloopV2.Config

  @spec claim(Config.t(), String.t()) :: :ok | {:error, term()}
  def claim(%Config{} = config, owner \\ "elixir") when is_binary(owner) do
    File.mkdir_p!(config.v2_state_dir)

    case read(config) do
      {:ok, %{"owner" => ^owner}} ->
        write_owner(config, owner)

      {:ok, %{"owner" => current}} when is_binary(current) and current not in ["", owner] ->
        {:error, {:active_runtime_owned_by, current}}

      _ ->
        write_owner(config, owner)
    end
  end

  @spec read(Config.t()) :: {:ok, map()} | :missing
  def read(%Config{} = config) do
    case File.read(path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _ -> :missing
        end

      _ ->
        :missing
    end
  end

  @spec path(Config.t()) :: Path.t()
  def path(%Config{} = config), do: Path.join(config.v2_state_dir, "active-runtime.json")

  defp write_owner(config, owner) do
    payload = %{
      "owner" => owner,
      "updated_at" => timestamp()
    }

    case File.write(path(config), Jason.encode!(payload, pretty: true) <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
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
      writers: [:daemon, :babysitter],
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

  @spec transition(Config.t(), atom(), atom(), map()) :: {:ok, ForgeloopV2.RuntimeState.t()} | {:error, term()}
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
      "plan" -> {:ok, Map.put(@transition_specs.loop_started, :transition, "planning")}
      "build" -> {:ok, Map.put(@transition_specs.loop_started, :transition, "building")}
      other when is_binary(other) and other != "" -> {:ok, Map.put(@transition_specs.loop_started, :transition, other)}
      _ -> {:error, {:invalid_runtime_mode, :loop_started}}
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
    Map.get(spec, :transition) || Map.get(attrs, :transition, Map.get(attrs, "transition", spec.status))
  end

  defp event_type(:paused_by_operator), do: "pause_detected"
  defp event_type(:recovered), do: "recovery_started"
  defp event_type(:loop_started), do: "loop_started"
  defp event_type(:loop_completed), do: "loop_completed"
  defp event_type(:failure_blocked), do: "loop_failed"
  defp event_type(_action), do: "runtime_transition"
end
