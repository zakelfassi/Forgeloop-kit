defmodule ForgeloopV2.PathPolicy do
  @moduledoc false

  alias ForgeloopV2.Config

  @spec workspace_root(Config.t()) :: Path.t()
  def workspace_root(%Config{} = config), do: Path.join(config.v2_state_dir, "workspaces")

  @spec validate_child(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_child(root, child) do
    expanded_root = Path.expand(root)
    expanded_child = Path.expand(child)

    cond do
      not path_inside?(expanded_child, expanded_root) ->
        {:error, {:path_outside_allowed_root, expanded_child, expanded_root}}

      true ->
        validate_resolved_parent(expanded_root, expanded_child)
    end
  end

  @spec validate_owned_path(Config.t(), Path.t(), :runtime | :workspace | :repo) :: {:ok, Path.t()} | {:error, term()}
  def validate_owned_path(%Config{} = config, path, scope) do
    root =
      case scope do
        :runtime -> config.runtime_dir
        :workspace -> workspace_root(config)
        :repo -> config.repo_root
      end

    validate_child(root, path)
  end

  defp validate_resolved_parent(root, path) do
    if Path.expand(path) == Path.expand(root) do
      {:ok, path}
    else
      validate_non_root_path(root, path)
    end
  end

  defp validate_non_root_path(root, path) do
    if symlink_escape?(root, path) do
      {:error, {:path_resolves_outside_allowed_root, path, Path.expand(root)}}
    else
      {:ok, path}
    end
  end

  defp symlink_escape?(root, path) do
    root = Path.expand(root)
    parent = Path.expand(Path.dirname(path))

    if not path_inside?(parent, root) do
      true
    else
      parent
      |> relative_segments(root)
      |> Enum.reduce_while(root, fn segment, current ->
        candidate = Path.join(current, segment)

        case File.lstat(candidate) do
          {:ok, %File.Stat{type: :symlink}} -> {:halt, true}
          {:ok, _stat} -> {:cont, candidate}
          {:error, :enoent} -> {:cont, candidate}
          {:error, _reason} -> {:halt, true}
        end
      end)
      |> Kernel.==(true)
    end
  end

  defp path_inside?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp relative_segments(path, root) do
    path
    |> String.replace_prefix(root <> "/", "")
    |> String.split("/", trim: true)
  end
end

defmodule ForgeloopV2.Workspace do
  @moduledoc false

  alias ForgeloopV2.{Config, PathPolicy}

  defstruct [
    :repo_root,
    :forgeloop_root,
    :runtime_dir,
    :workspace_root,
    :workspace_id,
    :slot_id,
    :branch,
    :mode,
    :kind
  ]

  @type t :: %__MODULE__{}

  @spec from_config(Config.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_config(%Config{} = config, opts \\ []) do
    workspace_root = PathPolicy.workspace_root(config)
    branch = Keyword.get(opts, :branch, config.default_branch)
    mode = Keyword.get(opts, :mode, "daemon")
    kind = Keyword.get(opts, :kind, mode)
    slot_id = Keyword.get(opts, :slot_id)

    with {:ok, validated_root} <- PathPolicy.validate_owned_path(config, workspace_root, :workspace) do
      {:ok,
       %__MODULE__{
         repo_root: config.repo_root,
         forgeloop_root: config.forgeloop_root,
         runtime_dir: config.runtime_dir,
         workspace_root: validated_root,
         workspace_id: workspace_id(config, branch, mode, kind, slot_id),
         slot_id: slot_id,
         branch: branch,
         mode: mode,
         kind: kind
       }}
    end
  end

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = workspace) do
    %{
      "workspace_id" => workspace.workspace_id,
      "workspace_slot_id" => workspace.slot_id,
      "workspace_branch" => workspace.branch,
      "workspace_mode" => workspace.mode,
      "workspace_kind" => workspace.kind
    }
  end

  defp workspace_id(config, branch, mode, kind, slot_id) do
    repo_slug = config.repo_root |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    base = Enum.join([repo_slug, branch, mode, kind, slot_id || ""], ":")
    short_hash = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    [
      repo_slug,
      sanitize(branch),
      sanitize(mode),
      sanitize(slot_id),
      short_hash
    ]
    |> Enum.reject(&is_nil_or_empty?/1)
    |> Enum.join("-")
  end

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp is_nil_or_empty?(nil), do: true
  defp is_nil_or_empty?(""), do: true
  defp is_nil_or_empty?(_value), do: false
end
