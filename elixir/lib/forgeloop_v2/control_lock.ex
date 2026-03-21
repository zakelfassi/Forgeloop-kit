defmodule ForgeloopV2.ControlLock do
  @moduledoc false

  alias ForgeloopV2.{Config, PathPolicy}

  @poll_interval_ms 25

  @spec with_lock(Config.t(), Path.t(), :repo | :runtime, keyword(), (() -> term())) ::
          {:ok, term()} | {:error, term()}
  def with_lock(%Config{} = config, target_path, scope, opts \\ [], fun) when is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, config.control_lock_timeout_ms)

    with {:ok, validated_target} <- PathPolicy.validate_owned_path(config, target_path, scope),
         {:ok, lock_dir} <- lock_dir(config, validated_target),
         :ok <- File.mkdir_p(Path.dirname(lock_dir)),
         :ok <- acquire_lock(lock_dir, validated_target, timeout_ms) do
      try do
        {:ok, fun.()}
      after
        release_lock(lock_dir)
      end
    end
  end

  @spec atomic_write(Config.t(), Path.t(), :repo | :runtime, iodata()) :: :ok | {:error, term()}
  def atomic_write(%Config{} = config, target_path, scope, body) do
    with {:ok, validated_target} <- PathPolicy.validate_owned_path(config, target_path, scope),
         {:ok, temp_path} <- temp_path(config, validated_target, scope),
         :ok <- File.mkdir_p(Path.dirname(validated_target)) do
      case File.write(temp_path, body) do
        :ok ->
          case File.rename(temp_path, validated_target) do
            :ok -> :ok
            {:error, _reason} = error ->
              _ = File.rm(temp_path)
              error
          end

        {:error, _reason} = error ->
          _ = File.rm(temp_path)
          error
      end
    end
  end

  defp lock_dir(%Config{} = config, validated_target) do
    hash =
      :crypto.hash(:sha256, validated_target)
      |> Base.encode16(case: :lower)

    lock_dir = Path.join([config.v2_state_dir, "locks", hash <> ".lock"])
    PathPolicy.validate_owned_path(config, lock_dir, :runtime)
  end

  defp temp_path(%Config{} = config, validated_target, scope) do
    dirname = Path.dirname(validated_target)
    basename = Path.basename(validated_target)
    candidate = Path.join(dirname, ".#{basename}.#{System.unique_integer([:positive])}.tmp")
    PathPolicy.validate_owned_path(config, candidate, scope)
  end

  defp acquire_lock(lock_dir, validated_target, :infinity) do
    case File.mkdir(lock_dir) do
      :ok -> write_lock_metadata(lock_dir, validated_target)
      {:error, :eexist} -> Process.sleep(@poll_interval_ms); acquire_lock(lock_dir, validated_target, :infinity)
      {:error, reason} -> {:error, {:lock_create_failed, lock_dir, reason}}
    end
  end

  defp acquire_lock(lock_dir, validated_target, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_acquire_lock(lock_dir, validated_target, deadline)
  end

  defp do_acquire_lock(lock_dir, validated_target, deadline) do
    case File.mkdir(lock_dir) do
      :ok -> write_lock_metadata(lock_dir, validated_target)

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:lock_timeout, validated_target, lock_dir}}
        else
          Process.sleep(@poll_interval_ms)
          do_acquire_lock(lock_dir, validated_target, deadline)
        end

      {:error, reason} ->
        {:error, {:lock_create_failed, lock_dir, reason}}
    end
  end

  defp write_lock_metadata(lock_dir, validated_target) do
    body =
      Jason.encode!(%{
        "target_path" => validated_target,
        "owner_pid" => inspect(self()),
        "node" => Atom.to_string(node()),
        "acquired_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }) <> "\n"

    case File.write(Path.join(lock_dir, "owner.json"), body) do
      :ok -> :ok
      {:error, reason} ->
        release_lock(lock_dir)
        {:error, {:lock_create_failed, lock_dir, reason}}
    end
  end

  defp release_lock(lock_dir) do
    _ = File.rm_rf(lock_dir)
    :ok
  end

end
