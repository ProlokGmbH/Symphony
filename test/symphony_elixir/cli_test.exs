defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "starts without the guardrails acknowledgement flag" do
    parent = self()

    deps = %{
      default_workflow_path: fn -> Path.expand("WORKFLOW.md") end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      load_env_files: fn path ->
        send(parent, {:env_loaded, path})
        :ok
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      validate_startup_requirements: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert :ok = CLI.evaluate([], deps)
    assert_received :file_checked
    assert_received {:env_loaded, env_path}
    assert env_path == "/tmp/project"
    assert_received :workflow_set
    assert_received :validated
    refute_received :logs_root_set
    refute_received :port_set
    assert_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    default_workflow_path = "/tmp/symphony-install/WORKFLOW.md"

    deps = %{
      default_workflow_path: fn -> default_workflow_path end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn path -> path == default_workflow_path end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([], deps)
  end

  test "still accepts the legacy guardrails acknowledgement flag" do
    default_workflow_path = "/tmp/symphony-install/WORKFLOW.md"

    deps = %{
      default_workflow_path: fn -> default_workflow_path end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn path -> path == default_workflow_path end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "rejects positional workflow path overrides" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["tmp/custom/WORKFLOW.md"], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>]"
  end

  test "loads env files from the invocation directory instead of the workflow directory" do
    parent = self()

    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == "/tmp/symphony-install/WORKFLOW.md"
      end,
      load_env_files: fn path ->
        send(parent, {:env_loaded, path})
        :ok
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      validate_startup_requirements: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([], deps)
    assert_received {:workflow_checked, "/tmp/symphony-install/WORKFLOW.md"}
    assert_received {:env_loaded, "/tmp/project"}
    assert_received {:workflow_set, "/tmp/symphony-install/WORKFLOW.md"}
    assert_received :validated
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> false end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([], deps)
  end

  test "returns env file error when loading workflow environment fails" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> {:error, {:invalid_env_file, "/tmp/.env.local", 3, :missing_assignment}} end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Failed to load environment for workflow"
    assert message =~ "/tmp/.env.local:3"
  end

  test "fails startup when LINEAR_ASSIGNEE is missing" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      env_files_dir: fn -> "/tmp/project" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> {:error, :missing_linear_assignee_env} end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ "LINEAR_ASSIGNEE must be set"
  end
end
