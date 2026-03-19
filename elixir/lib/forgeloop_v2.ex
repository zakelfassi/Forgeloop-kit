defmodule ForgeloopV2 do
  @moduledoc """
  Experimental Elixir foundation for Forgeloop v2.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    ForgeloopV2.Daemon.start_link(opts)
  end
end

defmodule ForgeloopV2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: ForgeloopV2.TaskSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ForgeloopV2.Supervisor
    )
  end
end
