defmodule SymphonyElixir.RuntimePathsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimePaths

  test "cleaned_system_env clears known runtime variables except explicit overrides" do
    default_env_map = RuntimePaths.cleaned_system_env() |> Map.new()
    env = RuntimePaths.cleaned_system_env(%{SYMPHONY_SOURCE_REPO: "/tmp/source"})
    env_map = Map.new(env)

    assert RuntimePaths.runtime_env_names() == SymphonyElixir.TestSupport.symphony_runtime_env_keys()
    assert default_env_map["SYMPHONY_SOURCE_REPO"] == nil
    assert env_map["SYMPHONY_SOURCE_REPO"] == "/tmp/source"
    assert env_map["SYMPHONY_WORKFLOW_FILE"] == nil
    assert env_map["SYMPHONY_PROJECT_ROOT"] == nil
  end

  test "cleaned_builtin_system_env sets current checkout values and clears non-builtins" do
    env = RuntimePaths.cleaned_builtin_system_env(%{"SYMPHONY_ACTIVE_REPO_ROOT" => "/tmp/active"})
    env_map = Map.new(env)

    assert env_map["SYMPHONY_ACTIVE_REPO_ROOT"] == "/tmp/active"
    assert env_map["SYMPHONY_PROJECT_ROOT"] == File.cwd!()
    assert env_map["SYMPHONY_PROJECT_WORKTREES_ROOT"] == RuntimePaths.project_worktrees_root()
    assert env_map["SYMPHONY_WORKFLOW_DIR"] == Path.dirname(RuntimePaths.workflow_file())
    assert env_map["SYMPHONY_WORKFLOW_FILE"] == RuntimePaths.workflow_file()
    assert env_map["SYMPHONY_SOURCE_REPO"] == nil
  end

  test "cleaned_builtin_port_env uses charlists and false for cleared variables" do
    default_env_map = RuntimePaths.cleaned_builtin_port_env() |> Map.new()
    env = RuntimePaths.cleaned_builtin_port_env(%{"SYMPHONY_SOURCE_REPO" => "/tmp/source"})
    env_map = Map.new(env)

    assert default_env_map[~c"SYMPHONY_SOURCE_REPO"] == false
    assert env_map[~c"SYMPHONY_SOURCE_REPO"] == ~c"/tmp/source"
    assert env_map[~c"SYMPHONY_PROJECT_ROOT"] == String.to_charlist(File.cwd!())
    assert env_map[~c"SYMPHONY_WORKFLOW_FILE"] == String.to_charlist(RuntimePaths.workflow_file())
    assert env_map[~c"SYMPHONY_WORKFLOW_DIALOG_FILE"] == false
    assert env_map[~c"SYMPHONY_WORKFLOW_INTERACTIVE_FILE"] == false
  end
end
