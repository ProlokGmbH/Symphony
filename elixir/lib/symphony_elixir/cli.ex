defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  # Keep the legacy acknowledgement flag accepted so older scripts still parse.
  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          default_workflow_path: (-> String.t()),
          file_regular?: (String.t() -> boolean()),
          load_env_files: (String.t() -> :ok | {:error, term()}),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          validate_startup_requirements: (-> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(deps.default_workflow_path.(), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      with :ok <- deps.load_env_files.(Path.dirname(expanded_path)),
           :ok <- deps.set_workflow_file_path.(expanded_path),
           :ok <- deps.validate_startup_requirements.() do
        case deps.ensure_all_started.() do
          {:ok, _started_apps} ->
            :ok

          {:error, reason} ->
            {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
        end
      else
        {:error, :missing_linear_assignee_env} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: LINEAR_ASSIGNEE must be set in the environment, .env, or .env.local"}

        {:error, :missing_linear_assignee} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: tracker.assignee must resolve to a non-empty value"}

        {:error, {:invalid_workflow_config, message}} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{message}"}

        {:error, :missing_linear_api_token} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: missing linear api token"}

        {:error, :missing_linear_project_slug} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: missing linear project slug"}

        {:error, reason} ->
          {:error, "Failed to load environment for workflow #{expanded_path}: #{format_env_file_error(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      default_workflow_path: &default_workflow_path/0,
      file_regular?: &File.regular?/1,
      load_env_files: &SymphonyElixir.EnvFile.load/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      validate_startup_requirements: &SymphonyElixir.Config.validate_startup_requirements/0,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp default_workflow_path do
    case :escript.script_name() do
      [] ->
        Path.expand("WORKFLOW.md")

      script_name ->
        script_name
        |> List.to_string()
        |> Path.dirname()
        |> Path.join("../WORKFLOW.md")
        |> Path.expand()
    end
  end

  defp format_env_file_error({:invalid_env_file, path, line_number, reason}) do
    "#{path}:#{line_number}: #{inspect(reason)}"
  end

  defp format_env_file_error({:env_file_read_failed, path, reason}) do
    "#{path}: #{inspect(reason)}"
  end

  defp format_env_file_error(reason), do: inspect(reason)

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
