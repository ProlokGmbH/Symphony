defmodule SymphonyElixir.RuntimePaths do
  @moduledoc false

  alias SymphonyElixir.Workflow

  @runtime_env_names [
    "SYMPHONY_WORKFLOW_FILE",
    "SYMPHONY_WORKFLOW_DIR",
    "SYMPHONY_WORKFLOW_DIALOG_FILE",
    "SYMPHONY_WORKFLOW_INTERACTIVE_FILE",
    "SYMPHONY_ACTIVE_REPO_ROOT",
    "SYMPHONY_SOURCE_REPO",
    "SYMPHONY_ISSUE_ID",
    "SYMPHONY_ISSUE_IDENTIFIER",
    "SYMPHONY_ISSUE_LABELS_JSON",
    "SYMPHONY_PROJECT_ROOT",
    "SYMPHONY_PROJECT_WORKTREES_ROOT"
  ]

  @spec runtime_env_names() :: [String.t()]
  def runtime_env_names, do: @runtime_env_names

  @spec project_root() :: Path.t()
  def project_root do
    File.cwd!()
  end

  @spec project_worktrees_root() :: Path.t()
  def project_worktrees_root do
    project_worktrees_base_root() <> "-worktrees"
  end

  @spec workflow_dir() :: Path.t()
  def workflow_dir do
    Workflow.default_workflow_file_path()
    |> Path.dirname()
  end

  @spec workflow_file() :: Path.t()
  def workflow_file do
    Workflow.workflow_file_path()
  end

  @spec builtin_env() :: %{String.t() => String.t()}
  def builtin_env do
    %{
      "SYMPHONY_PROJECT_ROOT" => project_root(),
      "SYMPHONY_PROJECT_WORKTREES_ROOT" => project_worktrees_root(),
      "SYMPHONY_WORKFLOW_DIR" => workflow_dir(),
      "SYMPHONY_WORKFLOW_FILE" => workflow_file()
    }
  end

  @spec cleaned_system_env(map()) :: [{String.t(), String.t() | nil}]
  def cleaned_system_env(overrides \\ %{}) when is_map(overrides) do
    normalized_overrides = stringify_env(overrides)

    @runtime_env_names
    |> Enum.reject(&Map.has_key?(normalized_overrides, &1))
    |> Enum.map(&{&1, nil})
    |> Kernel.++(Enum.to_list(normalized_overrides))
  end

  @spec cleaned_builtin_system_env(map()) :: [{String.t(), String.t() | nil}]
  def cleaned_builtin_system_env(overrides \\ %{}) when is_map(overrides) do
    builtin_env()
    |> Map.merge(stringify_env(overrides))
    |> cleaned_system_env()
  end

  @spec cleaned_builtin_port_env(map()) :: [{charlist(), charlist() | false}]
  def cleaned_builtin_port_env(overrides \\ %{}) when is_map(overrides) do
    normalized_overrides =
      builtin_env()
      |> Map.merge(stringify_env(overrides))

    clears =
      @runtime_env_names
      |> Enum.reject(&Map.has_key?(normalized_overrides, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    values =
      Enum.map(normalized_overrides, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    clears ++ values
  end

  @spec resolve_builtin_env(String.t()) :: String.t() | nil
  def resolve_builtin_env(name) when is_binary(name) do
    Map.get(builtin_env(), name)
  end

  defp stringify_env(env) when is_map(env) do
    Map.new(env, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp project_worktrees_base_root do
    cwd = project_root()

    case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> cwd
          common_dir -> Path.expand("..", common_dir)
        end

      {_output, _status} ->
        cwd
    end
  end
end
