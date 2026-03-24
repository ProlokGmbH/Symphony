defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application
  alias SymphonyElixir.{Config, EnvFile}

  @spec startup_preflight() :: :ok | {:error, term()}
  def startup_preflight do
    case EnvFile.load(File.cwd!()) do
      :ok -> Config.validate_startup_requirements()
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start(_type, _args) do
    with :ok <- startup_preflight(),
         :ok <- SymphonyElixir.LogFile.configure() do
      children = [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator,
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]

      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
