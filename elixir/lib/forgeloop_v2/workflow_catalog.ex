defmodule ForgeloopV2.WorkflowCatalog.Entry do
  @moduledoc false

  defstruct [
    :name,
    :root,
    :graph_file,
    :config_file,
    :prompts_dir,
    :scripts_dir,
    :runner_kind
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          root: Path.t(),
          graph_file: Path.t(),
          config_file: Path.t(),
          prompts_dir: Path.t() | nil,
          scripts_dir: Path.t() | nil,
          runner_kind: atom() | nil
        }
end

defmodule ForgeloopV2.WorkflowCatalog do
  @moduledoc false

  alias ForgeloopV2.Config
  alias ForgeloopV2.WorkflowCatalog.Entry

  @graph_file_name "workflow.dot"
  @config_file_name "workflow.toml"
  @runner_kind :workflow_pack_runner

  @spec list(Config.t()) :: [Entry.t()]
  def list(%Config{} = config) do
    config.workflow_search_dirs
    |> Enum.reduce(%{}, fn search_dir, acc ->
      list_from_dir(search_dir)
      |> Enum.reduce(acc, fn {name, entry}, entries ->
        Map.put_new(entries, name, entry)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec fetch(Config.t(), String.t()) :: {:ok, Entry.t()} | :missing | {:error, term()}
  def fetch(%Config{} = config, name) when is_binary(name) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_workflow_name, name}}

      true ->
        config.workflow_search_dirs
        |> Enum.reduce_while(:missing, fn search_dir, _acc ->
          case entry_from_search_dir(search_dir, name) do
            {:ok, entry} -> {:halt, {:ok, entry}}
            :missing -> {:cont, :missing}
          end
        end)
    end
  end

  defp list_from_dir(search_dir) do
    if File.dir?(search_dir) do
      search_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reduce([], fn name, acc ->
        case entry_from_search_dir(search_dir, name) do
          {:ok, entry} -> [{name, entry} | acc]
          :missing -> acc
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  end

  defp entry_from_search_dir(search_dir, name) do
    package_root = package_root(search_dir, name)

    if valid_name?(name) and runnable_package?(package_root) do
      {:ok, entry_from_package_root(package_root, name)}
    else
      :missing
    end
  end

  defp entry_from_package_root(package_root, name) do
    %Entry{
      name: name,
      root: package_root,
      graph_file: Path.join(package_root, @graph_file_name),
      config_file: Path.join(package_root, @config_file_name),
      prompts_dir: optional_dir(package_root, "prompts"),
      scripts_dir: optional_dir(package_root, "scripts"),
      runner_kind: @runner_kind
    }
  end

  defp runnable_package?(package_root) do
    File.dir?(package_root) and
      File.exists?(Path.join(package_root, @graph_file_name)) and
      File.exists?(Path.join(package_root, @config_file_name))
  end

  defp package_root(search_dir, name), do: Path.join(search_dir, name)
  defp valid_name?(name), do: String.match?(name, ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/)

  defp optional_dir(root, child) do
    path = Path.join(root, child)
    if File.dir?(path), do: path, else: nil
  end
end
