defmodule ForgeloopV2.PlanStore.Item do
  @moduledoc false

  @type status :: :pending | :completed

  @type t :: %__MODULE__{
          line_number: pos_integer(),
          section: String.t() | nil,
          text: String.t(),
          depth: non_neg_integer(),
          status: status(),
          raw_line: String.t()
        }

  defstruct [:line_number, :section, :text, :depth, :status, :raw_line]
end

defmodule ForgeloopV2.PlanStore.Backlog do
  @moduledoc false

  alias ForgeloopV2.PlanStore.Item

  @type source :: %{
          kind: :implementation_plan,
          label: String.t(),
          path: String.t(),
          canonical?: boolean(),
          phase: String.t()
        }

  @type t :: %__MODULE__{
          source: source(),
          exists?: boolean(),
          needs_build?: boolean(),
          items: [Item.t()]
        }

  defstruct [:source, :exists?, :needs_build?, items: []]
end

defmodule ForgeloopV2.PlanStore do
  @moduledoc false

  alias ForgeloopV2.Config
  alias ForgeloopV2.PlanStore.{Backlog, Item}

  @spec read(Config.t()) :: {:ok, [Item.t()]} | :missing | {:error, term()}
  def read(%Config{} = config) do
    case File.read(config.plan_file) do
      {:ok, body} -> {:ok, parse_items(body)}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec summary(Config.t()) :: {:ok, Backlog.t()}
  def summary(%Config{} = config) do
    source = source_metadata(config)

    case read(config) do
      {:ok, items} ->
        pending = Enum.filter(items, &(&1.status == :pending))

        {:ok,
         %Backlog{
           source: source,
           exists?: true,
           needs_build?: Enum.any?(pending, &(&1.depth == 0)),
           items: pending
         }}

      :missing ->
        {:ok,
         %Backlog{
           source: source,
           exists?: false,
           needs_build?: true,
           items: []
         }}

      {:error, _reason} ->
        {:ok,
         %Backlog{
           source: source,
           exists?: File.exists?(config.plan_file),
           needs_build?: true,
           items: []
         }}
    end
  end

  @spec pending_items(Config.t()) :: [Item.t()]
  def pending_items(%Config{} = config) do
    {:ok, %Backlog{items: items}} = summary(config)
    items
  end

  @spec needs_build?(Config.t()) :: boolean()
  def needs_build?(%Config{} = config) do
    {:ok, %Backlog{needs_build?: needs_build?}} = summary(config)
    needs_build?
  end

  defp source_metadata(%Config{} = config) do
    %{
      kind: :implementation_plan,
      label: Path.basename(config.plan_file),
      path: config.plan_file,
      canonical?: true,
      phase: "phase1"
    }
  end

  defp parse_items(body) do
    body
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, line_number}, {section, acc} ->
      case parse_line(line, line_number, section) do
        {:section, next_section} -> {next_section, acc}
        {:item, item} -> {section, [item | acc]}
        :ignore -> {section, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp parse_line(line, line_number, section) do
    cond do
      match = Regex.run(~r/^##\s+(.+?)\s*$/, line, capture: :all_but_first) ->
        {:section, List.first(match)}

      match = Regex.run(~r/^([ \t]*)-\s\[( |x|X)\]\s*(.*)$/, line, capture: :all_but_first) ->
        [indent, marker, text] = match

        {:item,
         %Item{
           line_number: line_number,
           section: section,
           text: String.trim(text),
           depth: indent_width(indent),
           status: if(marker == " ", do: :pending, else: :completed),
           raw_line: line
         }}

      true ->
        :ignore
    end
  end

  defp indent_width(indent) do
    indent
    |> String.replace("\t", "  ")
    |> String.length()
  end
end
