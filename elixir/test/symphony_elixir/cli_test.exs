defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "starts without the guardrails acknowledgement flag" do
    parent = self()

    deps = %{
      default_workflow_path: fn -> Path.expand("WORKFLOW.md") end,
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

    assert :ok = CLI.evaluate(["WORKFLOW.md"], deps)
    assert_received :file_checked
    assert_received {:env_loaded, env_path}
    assert env_path == Path.expand(".")
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

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
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

    assert :ok = CLI.evaluate([workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:env_loaded, env_dir}
    assert env_dir == Path.dirname(expanded_path)
    assert_received {:workflow_set, ^expanded_path}
    assert_received :validated
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
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

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn _path -> false end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["WORKFLOW.md"], deps)
  end

  test "returns env file error when loading workflow environment fails" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> {:error, {:invalid_env_file, "/tmp/.env.local", 3, :missing_assignment}} end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Failed to load environment for workflow"
    assert message =~ "/tmp/.env.local:3"
  end

  test "fails startup when LINEAR_ASSIGNEE is missing" do
    deps = %{
      default_workflow_path: fn -> "/tmp/symphony-install/WORKFLOW.md" end,
      file_regular?: fn _path -> true end,
      load_env_files: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_startup_requirements: fn -> {:error, :missing_linear_assignee_env} end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ "LINEAR_ASSIGNEE must be set"
  end
end
