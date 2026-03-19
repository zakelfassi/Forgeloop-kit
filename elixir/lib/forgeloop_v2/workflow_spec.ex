defmodule ForgeloopV2.Workflow.Spec do
  @moduledoc false

  defstruct version: 1,
            tracker: %{"kind" => "memory"},
            selection: %{"states" => []},
            states: %{},
            agent: %{},
            raw: %{}

  @type t :: %__MODULE__{}

  @allowed_top_level_keys ~w(version tracker selection states agent)
  @forbidden_top_level_keys ~w(workspace runtime deployment providers persistence events dashboard phoenix postgres)

  @spec normalize(map()) :: {:ok, t()} | {:error, term()}
  def normalize(raw_config) when is_map(raw_config) do
    config = stringify_keys(raw_config)
    keys = Map.keys(config)

    with :ok <- validate_forbidden_keys(keys),
         :ok <- validate_unknown_keys(keys),
         {:ok, version} <- normalize_version(Map.get(config, "version", 1)),
         {:ok, tracker} <- normalize_tracker(Map.get(config, "tracker", %{})),
         {:ok, selection} <- normalize_selection(Map.get(config, "selection", %{})),
         {:ok, states} <- normalize_states(Map.get(config, "states", %{})),
         {:ok, agent} <- normalize_agent(Map.get(config, "agent", %{})) do
      {:ok,
       %__MODULE__{
         version: version,
         tracker: tracker,
         selection: selection,
         states: states,
         agent: agent,
         raw: config
       }}
    end
  end

  defp validate_forbidden_keys(keys) do
    forbidden = Enum.filter(keys, &(&1 in @forbidden_top_level_keys))
    if forbidden == [], do: :ok, else: {:error, {:workflow_forbidden_keys, forbidden}}
  end

  defp validate_unknown_keys(keys) do
    unknown = Enum.reject(keys, &(&1 in @allowed_top_level_keys or &1 in @forbidden_top_level_keys))
    if unknown == [], do: :ok, else: {:error, {:workflow_unknown_keys, unknown}}
  end

  defp normalize_version(1), do: {:ok, 1}
  defp normalize_version("1"), do: {:ok, 1}
  defp normalize_version(other), do: {:error, {:unsupported_workflow_version, other}}

  defp normalize_tracker(value) when is_map(value) do
    tracker = stringify_keys(value)
    kind = Map.get(tracker, "kind", "memory")

    if is_binary(kind) and String.trim(kind) != "" do
      {:ok, %{"kind" => kind}}
    else
      {:error, {:invalid_workflow_tracker, tracker}}
    end
  end

  defp normalize_tracker(_value), do: {:error, {:invalid_workflow_tracker, :not_a_map}}

  defp normalize_selection(value) when is_map(value) do
    selection = stringify_keys(value)
    states = Map.get(selection, "states", [])

    cond do
      is_list(states) and Enum.all?(states, &is_binary/1) ->
        {:ok, %{"states" => states}}

      true ->
        {:error, {:invalid_workflow_selection, selection}}
    end
  end

  defp normalize_selection(_value), do: {:error, {:invalid_workflow_selection, :not_a_map}}

  defp normalize_states(value) when is_map(value), do: {:ok, stringify_keys(value)}
  defp normalize_states(_value), do: {:error, {:invalid_workflow_states, :not_a_map}}

  defp normalize_agent(value) when is_map(value) do
    agent = stringify_keys(value)

    case Map.get(agent, "max_turns") do
      nil -> {:ok, agent}
      turns when is_integer(turns) and turns > 0 -> {:ok, agent}
      "0" -> {:error, {:invalid_workflow_agent, agent}}
      turns when is_binary(turns) ->
        case Integer.parse(turns) do
          {parsed, ""} when parsed > 0 -> {:ok, Map.put(agent, "max_turns", parsed)}
          _ -> {:error, {:invalid_workflow_agent, agent}}
        end

      _ ->
        {:error, {:invalid_workflow_agent, agent}}
    end
  end

  defp normalize_agent(_value), do: {:error, {:invalid_workflow_agent, :not_a_map}}

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
    |> Map.new()
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
