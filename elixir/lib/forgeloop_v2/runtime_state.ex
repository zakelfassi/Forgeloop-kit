defmodule ForgeloopV2.RuntimeState do
  @moduledoc false

  defstruct previous_status: "",
            status: "",
            transition: "",
            surface: "",
            mode: "",
            reason: "",
            requested_action: "",
            branch: "",
            updated_at: ""

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      previous_status: string_value(map, "previous_status"),
      status: string_value(map, "status"),
      transition: string_value(map, "transition"),
      surface: string_value(map, "surface"),
      mode: string_value(map, "mode"),
      reason: string_value(map, "reason"),
      requested_action: string_value(map, "requested_action"),
      branch: string_value(map, "branch"),
      updated_at: string_value(map, "updated_at")
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      "previous_status" => state.previous_status,
      "status" => state.status,
      "transition" => state.transition,
      "surface" => state.surface,
      "mode" => state.mode,
      "reason" => state.reason,
      "requested_action" => state.requested_action,
      "branch" => state.branch,
      "updated_at" => state.updated_at
    }
  end

  defp string_value(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key), "") || ""
  end
end

defmodule ForgeloopV2.RuntimeStateStore do
  @moduledoc false

  alias ForgeloopV2.{Config, RuntimeState}

  @spec read(Config.t()) :: {:ok, RuntimeState.t()} | :missing | {:error, term()}
  def read(%Config{} = config) do
    case File.read(config.runtime_state_file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, RuntimeState.from_map(payload)}
          {:ok, _} -> :missing
          {:error, _reason} -> :missing
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec status(Config.t()) :: String.t()
  def status(%Config{} = config) do
    case read(config) do
      {:ok, state} -> state.status
      _ -> ""
    end
  end

  @spec write(Config.t(), map()) :: {:ok, RuntimeState.t()} | {:error, term()}
  def write(%Config{} = config, attrs) when is_map(attrs) do
    File.mkdir_p!(Path.dirname(config.runtime_state_file))

    previous =
      case read(config) do
        {:ok, state} -> state
        _ -> %RuntimeState{}
      end

    state =
      %RuntimeState{
        previous_status: previous.status,
        status: string_attr(attrs, :status),
        transition: string_attr(attrs, :transition, string_attr(attrs, :status)),
        surface: string_attr(attrs, :surface, "unknown"),
        mode: string_attr(attrs, :mode, "unknown"),
        reason: string_attr(attrs, :reason),
        requested_action: string_attr(attrs, :requested_action),
        branch: string_attr(attrs, :branch),
        updated_at: iso_now()
      }

    tmp_path = config.runtime_state_file <> ".tmp"
    body = Jason.encode!(RuntimeState.to_map(state), pretty: true) <> "\n"

    with :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, config.runtime_state_file) do
      _ = File.chmod(config.runtime_state_file, 0o600)
      {:ok, state}
    end
  end

  defp string_attr(attrs, key, default \\ "") do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    cond do
      is_nil(value) -> default
      is_binary(value) -> value
      is_atom(value) -> Atom.to_string(value)
      true -> to_string(value)
    end
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
