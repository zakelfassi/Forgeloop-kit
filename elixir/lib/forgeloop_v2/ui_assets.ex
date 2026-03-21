defmodule ForgeloopV2.UIAssets do
  @moduledoc false

  alias ForgeloopV2.Config

  @asset_map %{
    "/" => {"index.html", "text/html; charset=utf-8"},
    "/index.html" => {"index.html", "text/html; charset=utf-8"},
    "/assets/app.css" => {"app.css", "text/css; charset=utf-8"},
    "/assets/app.js" => {"app.js", "application/javascript; charset=utf-8"}
  }

  @spec validate!(Config.t()) :: :ok | {:error, term()}
  def validate!(%Config{} = config) do
    Enum.reduce_while(@asset_map, :ok, fn {_request_path, {relative_path, _content_type}}, _acc ->
      absolute_path = asset_path(config, relative_path)

      if File.regular?(absolute_path) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_static_asset, absolute_path}}}
      end
    end)
  end

  @spec fetch(Config.t(), String.t()) :: {:ok, map()} | :missing | {:error, term()}
  def fetch(%Config{} = config, request_path) do
    case Map.get(@asset_map, request_path) do
      nil ->
        :missing

      {relative_path, content_type} ->
        absolute_path = asset_path(config, relative_path)

        case File.read(absolute_path) do
          {:ok, body} -> {:ok, %{content_type: content_type, body: body, path: absolute_path}}
          {:error, :enoent} -> {:error, {:missing_static_asset, absolute_path}}
          {:error, reason} -> {:error, {:asset_read_failed, absolute_path, reason}}
        end
    end
  end

  @spec ui_root(Config.t()) :: String.t()
  def ui_root(%Config{} = config), do: Path.join([config.forgeloop_root, "elixir", "priv", "static", "ui"])

  defp asset_path(config, relative_path), do: Path.join(ui_root(config), relative_path)
end
