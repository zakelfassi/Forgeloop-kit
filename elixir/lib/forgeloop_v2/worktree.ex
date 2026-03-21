defmodule ForgeloopV2.Worktree.Handle do
  @moduledoc false

  alias ForgeloopV2.Workspace

  defstruct [
    :workspace,
    :checkout_path,
    :checkout_forgeloop_root,
    :loop_script_path,
    :metadata_file,
    :checkout_ref
  ]

  @type t :: %__MODULE__{
          workspace: Workspace.t(),
          checkout_path: Path.t(),
          checkout_forgeloop_root: Path.t(),
          loop_script_path: Path.t(),
          metadata_file: Path.t(),
          checkout_ref: String.t()
        }
end

defmodule ForgeloopV2.Worktree do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock, Events, PathPolicy, Workspace}
  alias ForgeloopV2.Worktree.Handle

  @spec babysitter_root(Config.t()) :: Path.t()
  def babysitter_root(%Config{} = config), do: Path.join(config.v2_state_dir, "babysitter")

  @spec active_run_path(Config.t()) :: Path.t()
  def active_run_path(%Config{} = config), do: Path.join(babysitter_root(config), "active-run.json")

  @spec metadata_dir(Config.t()) :: Path.t()
  def metadata_dir(%Config{} = config), do: Path.join([babysitter_root(config), "worktrees"])

  @spec metadata_path(Config.t(), String.t()) :: Path.t()
  def metadata_path(%Config{} = config, workspace_id), do: Path.join(metadata_dir(config), workspace_id <> ".json")

  @spec read_active_run(Config.t()) :: {:ok, map()} | :missing | {:error, term()}
  def read_active_run(%Config{} = config) do
    case File.read(active_run_path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, _payload} -> {:error, :invalid_active_run_payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prepare(Config.t(), Workspace.t(), keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def prepare(%Config{} = config, %Workspace{} = workspace, _opts \\ []) do
    with :ok <- ensure_clean_repo(config),
         {:ok, checkout_ref} <- current_ref(config),
         {:ok, checkout_path} <- checkout_path(config, workspace),
         {:ok, metadata_file} <- metadata_path_for_workspace(config, workspace),
         {:ok, checkout_forgeloop_root} <- checkout_forgeloop_root(config, checkout_path),
         {:ok, loop_script_path} <- checkout_loop_script_path(config, checkout_forgeloop_root),
         :ok <- remove_existing_checkout(config, checkout_path),
         {:ok, _output} <- git(config, ["worktree", "add", "--detach", checkout_path, checkout_ref]) do
      handle = %Handle{
        workspace: workspace,
        checkout_path: checkout_path,
        checkout_forgeloop_root: checkout_forgeloop_root,
        loop_script_path: loop_script_path,
        metadata_file: metadata_file,
        checkout_ref: checkout_ref
      }

      case persist_handle(config, handle) do
        :ok ->
          Events.emit(config, :worktree_prepared, %{
            "workspace_id" => workspace.workspace_id,
            "checkout_path" => checkout_path,
            "checkout_ref" => checkout_ref
          })

          {:ok, handle}

        {:error, reason} ->
          _ = cleanup(config, handle)
          {:error, reason}
      end
    end
  end

  @spec cleanup(Config.t(), Handle.t() | String.t(), keyword()) :: :ok | {:error, term()}
  def cleanup(config, handle_or_workspace_id, opts \\ [])

  def cleanup(%Config{} = config, %Handle{} = handle, _opts) do
    with :ok <- remove_checkout(config, handle.checkout_path),
         :ok <- File.rm(handle.metadata_file) |> ignore_missing() do
      Events.emit(config, :worktree_cleaned, %{
        "workspace_id" => handle.workspace.workspace_id,
        "checkout_path" => handle.checkout_path
      })

      _ = File.rm_rf(handle.checkout_path)
      :ok
    end
  end

  def cleanup(%Config{} = config, workspace_id, opts) when is_binary(workspace_id) do
    case load_handle(config, workspace_id) do
      {:ok, handle} -> cleanup(config, handle, opts)
      :missing -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup_stale(Config.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def cleanup_stale(%Config{} = config, opts \\ []) do
    lock_opts = [timeout_ms: Keyword.get(opts, :timeout_ms, config.control_lock_timeout_ms)]

    with {:ok, result} <-
           ControlLock.with_lock(config, active_run_path(config), :runtime, lock_opts, fn ->
             active_workspace_id = stale_active_workspace_id(config)
             metadata_workspace_ids = metadata_workspace_ids(config)

             workspace_ids =
               ([active_workspace_id] ++ metadata_workspace_ids)
               |> Enum.reject(&is_nil/1)
               |> Enum.uniq()

             cleaned =
               Enum.reduce(workspace_ids, [], fn workspace_id, acc ->
                 case cleanup(config, workspace_id) do
                   :ok -> [workspace_id | acc]
                   {:error, _reason} -> acc
                 end
               end)

             _ = File.rm(active_run_path(config))
             Enum.reverse(cleaned)
           end) do
      {:ok, result}
    end
  end

  defp ensure_clean_repo(%Config{} = config) do
    with {:ok, output} <- git(config, ["status", "--porcelain"]) do
      lines = output |> String.split("\n", trim: true)

      dirty_lines =
        lines
        |> Enum.reject(&ignorable_dirty_line?(config, &1))

      if dirty_lines == [] do
        :ok
      else
        {:error, {:dirty_repo, dirty_lines}}
      end
    end
  end

  defp current_ref(%Config{} = config) do
    with {:ok, output} <- git(config, ["rev-parse", "HEAD"]) do
      {:ok, String.trim(output)}
    end
  end

  defp checkout_path(%Config{} = config, %Workspace{} = workspace) do
    path = Path.join(workspace.workspace_root, workspace.workspace_id)
    PathPolicy.validate_owned_path(config, path, :workspace)
  end

  defp metadata_path_for_workspace(%Config{} = config, %Workspace{} = workspace) do
    path = metadata_path(config, workspace.workspace_id)
    PathPolicy.validate_owned_path(config, path, :runtime)
  end

  defp checkout_forgeloop_root(%Config{} = config, checkout_path) do
    with {:ok, relative} <- relative_inside(config.forgeloop_root, config.repo_root, :forgeloop_root_outside_repo) do
      target = if relative == ".", do: checkout_path, else: Path.join(checkout_path, relative)
      PathPolicy.validate_owned_path(config, target, :workspace)
    end
  end

  defp checkout_loop_script_path(%Config{} = config, checkout_forgeloop_root) do
    with {:ok, relative} <- relative_inside(config.loop_script, config.forgeloop_root, :loop_script_outside_forgeloop_root) do
      candidate = Path.expand(relative, checkout_forgeloop_root)
      PathPolicy.validate_owned_path(config, candidate, :workspace)
    end
  end

  defp relative_inside(path, root, error_tag) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    relative = Path.relative_to(expanded_path, expanded_root)

    if relative == expanded_path or String.starts_with?(relative, "../") do
      {:error, {error_tag, expanded_path, expanded_root}}
    else
      {:ok, relative}
    end
  end

  defp persist_handle(%Config{} = config, %Handle{} = handle) do
    body = Jason.encode!(handle_payload(config, handle), pretty: true) <> "\n"
    File.mkdir_p!(metadata_dir(config))
    ControlLock.atomic_write(config, handle.metadata_file, :runtime, body)
  end

  defp handle_payload(%Config{} = config, %Handle{} = handle) do
    %{
      "workspace_id" => handle.workspace.workspace_id,
      "checkout_path" => handle.checkout_path,
      "checkout_forgeloop_root" => handle.checkout_forgeloop_root,
      "loop_script_path" => handle.loop_script_path,
      "metadata_file" => handle.metadata_file,
      "checkout_ref" => handle.checkout_ref,
      "canonical_repo_root" => config.repo_root,
      "canonical_forgeloop_root" => config.forgeloop_root,
      "created_at" => iso_now()
    }
  end

  defp load_handle(%Config{} = config, workspace_id) do
    path = metadata_path(config, workspace_id)

    case File.read(path) do
      {:ok, body} ->
        with {:ok, payload} when is_map(payload) <- Jason.decode(body),
             %{"checkout_path" => checkout_path, "checkout_forgeloop_root" => checkout_forgeloop_root,
               "loop_script_path" => loop_script_path, "checkout_ref" => checkout_ref} <- payload,
             {:ok, workspace} <- Workspace.from_config(config, branch: config.default_branch, mode: "build", kind: "babysitter") do
          {:ok,
           %Handle{
             workspace: %{workspace | workspace_id: workspace_id},
             checkout_path: checkout_path,
             checkout_forgeloop_root: checkout_forgeloop_root,
             loop_script_path: loop_script_path,
             metadata_file: path,
             checkout_ref: checkout_ref
           }}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, {:invalid_worktree_metadata, path}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_existing_checkout(%Config{} = config, checkout_path) do
    _ = remove_checkout(config, checkout_path)
    :ok
  end

  defp remove_checkout(%Config{} = config, checkout_path) do
    path_exists? = File.exists?(checkout_path)

    result =
      if path_exists? do
        git(config, ["worktree", "remove", "--force", checkout_path])
      else
        {:ok, ""}
      end

    with {:ok, _} <- result,
         {:ok, _} <- git(config, ["worktree", "prune"]) do
      :ok
    else
      {:error, {:git_failed, _args, output}} = error ->
        if String.contains?(output, "is not a working tree") or String.contains?(output, "not found") do
          :ok
        else
          error
        end

      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_active_workspace_id(%Config{} = config) do
    case File.read(active_run_path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"workspace_id" => workspace_id}} when is_binary(workspace_id) and workspace_id != "" -> workspace_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp metadata_workspace_ids(%Config{} = config) do
    metadata_dir = metadata_dir(config)

    if File.dir?(metadata_dir) do
      metadata_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.rootname(Path.basename(&1)))
    else
      []
    end
  end

  defp ignorable_dirty_line?(%Config{} = config, line) do
    case dirty_line_path(line) do
      nil -> false
      relative_path -> ignorable_dirty_path?(config, relative_path)
    end
  end

  defp dirty_line_path(line) do
    case String.split(String.slice(line, 3..-1//1) || "", " -> ") do
      [] -> nil
      parts -> parts |> List.last() |> String.trim() |> blank_to_nil()
    end
  end

  defp ignorable_dirty_path?(%Config{} = config, relative_path) do
    allowed = [
      relative_to_repo(config, config.requests_file),
      relative_to_repo(config, config.questions_file),
      relative_to_repo(config, config.escalations_file),
      relative_to_repo(config, config.plan_file)
    ]

    runtime_relative = relative_to_repo(config, config.runtime_dir)

    relative_path in allowed or
      (is_binary(runtime_relative) and runtime_relative != "." and String.starts_with?(relative_path, runtime_relative <> "/"))
  end

  defp relative_to_repo(%Config{} = config, path) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(config.repo_root)
    relative = Path.relative_to(expanded_path, expanded_root)

    if relative == expanded_path or String.starts_with?(relative, "../") do
      nil
    else
      relative
    end
  end

  defp git(%Config{} = config, args) do
    case System.cmd("git", ["-C", config.repo_root | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:git_failed, args, output}}
    end
  rescue
    error -> {:error, {:git_exec_failed, args, error}}
  end

  defp ignore_missing(:ok), do: :ok
  defp ignore_missing({:error, :enoent}), do: :ok
  defp ignore_missing(other), do: other

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
