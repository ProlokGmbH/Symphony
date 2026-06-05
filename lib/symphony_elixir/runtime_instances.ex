defmodule SymphonyElixir.RuntimeInstances do
  @moduledoc """
  Counts active Symphony runtime instances from the operating system process table.
  """

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec active_count() :: pos_integer()
  def active_count do
    active_count(&System.cmd/3)
  end

  @spec active_count(command_runner()) :: pos_integer()
  def active_count(command_runner) when is_function(command_runner, 3) do
    case command_runner.("ps", ["-axo", "command="], stderr_to_stdout: true) do
      {output, 0} when is_binary(output) -> count_from_ps_output(output)
      _result -> 1
    end
  rescue
    _reason -> 1
  catch
    _kind, _reason -> 1
  end

  @spec count_from_ps_output(String.t()) :: pos_integer()
  def count_from_ps_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> count_commands()
  end

  @spec count_commands([String.t()]) :: pos_integer()
  def count_commands(commands) when is_list(commands) do
    commands
    |> Enum.count(&symphony_process_command?/1)
    |> max(1)
  end

  defp symphony_process_command?(command) when is_binary(command) do
    command
    |> String.split()
    |> List.first()
    |> symphony_executable_path?()
  end

  defp symphony_executable_path?(nil), do: false

  defp symphony_executable_path?(path) when is_binary(path) do
    normalized_path =
      path
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> String.trim_leading("'")
      |> String.trim_trailing("'")

    parent_dir =
      normalized_path
      |> Path.dirname()
      |> Path.basename()

    Path.basename(normalized_path) == "symphony" and parent_dir == "bin"
  end
end
