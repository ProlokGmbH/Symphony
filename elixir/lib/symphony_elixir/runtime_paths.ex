defmodule SymphonyElixir.RuntimePaths do
  @moduledoc false

  alias SymphonyElixir.Workflow

  @spec project_root() :: Path.t()
  def project_root do
    File.cwd!()
  end

  @spec project_worktrees_root() :: Path.t()
  def project_worktrees_root do
    project_root() <> "-worktrees"
  end

  @spec workflow_dir() :: Path.t()
  def workflow_dir do
    Workflow.workflow_file_path()
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

  @spec resolve_builtin_env(String.t()) :: String.t() | nil
  def resolve_builtin_env(name) when is_binary(name) do
    Map.get(builtin_env(), name)
  end
end
