defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ScriptSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000

    assert config.tracker.active_states == [
             "Todo (AI)",
             "Planung (AI)",
             "In Arbeit (AI)",
             "PreReview (AI)",
             "Review (AI)",
             "Test (AI)",
             "Abbruch (AI)",
             "Merge (AI)"
           ]

    assert config.tracker.terminal_states == ["Review", "Fertig", "Abgebrochen"]
    assert config.tracker.assignee == "dev@example.com"
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Freigabe,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "set -eu"
    assert Map.get(hooks, "after_create") =~ "branch=\"symphony/$issue_key\""
    assert Map.get(hooks, "after_create") =~ "source_repo=\"$SYMPHONY_PROJECT_ROOT\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$workspace\" rev-parse --is-inside-work-tree"
    assert Map.get(hooks, "after_create") =~ "rm -rf \"$workspace\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" fetch origin"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add \"$workspace\" \"$branch\""
    assert Map.get(hooks, "after_create") =~ "refs/remotes/origin/$branch"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add --track -b \"$branch\" \"$workspace\" \"origin/$branch\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$workspace\" pull --ff-only origin \"$branch\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add -b \"$branch\" \"$workspace\" origin/main"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" config \"branch.$branch.remote\" origin"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" config \"branch.$branch.merge\" \"refs/heads/$branch\""
    assert Map.get(hooks, "after_create") =~ "cp \"$source_repo/.env.local\" \"$workspace/.env.local\""
    refute Map.has_key?(hooks, "on_worktree_commit")
    assert Map.get(hooks, "before_remove") =~ "workspace=\"$PWD\""
    assert Map.get(hooks, "before_remove") =~ "cd \"$SYMPHONY_WORKFLOW_DIR\" && mise exec -- mix workspace.before_remove --workspace \"$workspace\" --source-repo \"$SYMPHONY_PROJECT_ROOT\""
    codex = Map.get(config, "codex", %{})
    assert is_map(codex)
    assert Map.get(codex, "command") =~ "git rev-parse --path-format=absolute --git-common-dir"
    assert Map.get(codex, "command") =~ "common_dir=\"$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)\"; if [ -z \"$common_dir\" ]; then"
    assert Map.get(codex, "command") =~ "exit 1;"
    assert Map.get(codex, "command") =~ "fi; source_repo=\"$(cd \"$common_dir/..\" && pwd -P)\";"
    assert Map.get(codex, "command") =~ "exec \"$source_repo/sym-codex\" --observer"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
    assert prompt =~ "Der kanonische Arbeitsbranch für dieses Issue heißt immer `symphony/{{ issue.identifier }}`."
    assert prompt =~ "Wenn ein frischer Branch benötigt wird, erstelle oder verwende genau `symphony/{{ issue.identifier }}` von `origin/main`."
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "startup validation requires LINEAR_ASSIGNEE in the environment" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.delete_env("LINEAR_ASSIGNEE")

    assert {:error, :missing_linear_assignee_env} = Config.validate_startup_requirements()

    System.put_env("LINEAR_ASSIGNEE", "dev@example.com")

    assert :ok = Config.validate_startup_requirements()
  end

  test "application startup preflight loads env files before validating assignee" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_workflow_path = Workflow.workflow_file_path()
    original_cwd = File.cwd!()

    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-#{System.unique_integer([:positive])}"
      )

    invocation_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-invocation-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
      Workflow.set_workflow_file_path(previous_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(workflow_root)
      File.rm_rf(invocation_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")
    File.mkdir_p!(workflow_root)
    File.mkdir_p!(invocation_root)

    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_path,
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    File.write!(Path.join(invocation_root, ".env.local"), "LINEAR_ASSIGNEE=dev@example.com\n")
    Workflow.set_workflow_file_path(workflow_path)
    File.cd!(invocation_root)

    assert :ok = SymphonyElixir.Application.startup_preflight()
    assert System.get_env("LINEAR_ASSIGNEE") == "dev@example.com"
  end

  test "application startup preflight returns env file errors from the invocation directory" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_workflow_path = Workflow.workflow_file_path()
    original_cwd = File.cwd!()

    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-invalid-workflow-#{System.unique_integer([:positive])}"
      )

    invocation_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-invalid-invocation-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
      Workflow.set_workflow_file_path(previous_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(workflow_root)
      File.rm_rf(invocation_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")
    File.mkdir_p!(workflow_root)
    File.mkdir_p!(invocation_root)

    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_path,
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    File.write!(Path.join(invocation_root, ".env"), "LINEAR_ASSIGNEE\n")
    Workflow.set_workflow_file_path(workflow_path)
    File.cd!(invocation_root)

    assert {:error, {:invalid_env_file, path, 1, :missing_assignment}} =
             SymphonyElixir.Application.startup_preflight()

    assert path == Path.join(invocation_root, ".env")
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory outside escript mode" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = Path.join(System.tmp_dir!(), "symphony-workflow-no-escript-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, [])

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path defaults relative to the launched symphony binary" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = Path.join(System.tmp_dir!(), "symphony-workflow-default-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path ignores non-Symphony projects even when they contain a workflow file" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = Path.join(System.tmp_dir!(), "symphony-workflow-generic-project-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.write!(Path.join(temp_root, "WORKFLOW.md"), "---\n---\n")

    File.write!(
      Path.join(temp_root, "mix.exs"),
      """
      defmodule GenericProject.MixProject do
        use Mix.Project

        def project do
          [app: :generic_project]
        end
      end
      """
    )

    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path ignores plain workflow files without a Symphony mix project" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = Path.join(System.tmp_dir!(), "symphony-workflow-no-mix-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.write!(Path.join(temp_root, "WORKFLOW.md"), "---\n---\n")

    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path prefers the current Symphony worktree when launched from a Symphony checkout" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path prefers the Symphony workflow when launched from the repo root" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    repo_root = File.cwd!()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.cd!(repo_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == Path.join(repo_root, "WORKFLOW.md")
  end

  test "workflow file path falls back to cwd for non-symphony executables" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = Path.join(System.tmp_dir!(), "symphony-workflow-cwd-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/usr/bin/elixir")

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_pid(Process.whereis(SymphonyElixir.Supervisor)) and
           is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) and is_pid(Process.whereis(SymphonyElixir.Supervisor)) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Fertig",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "cancel issue state stops running agent, cleans workspace, and moves issue to Abgebrochen" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-cancel"
    issue_identifier = "MT-556-C"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: [
          "Todo (AI)",
          "In Arbeit (AI)",
          "Review (AI)",
          "Abbruch (AI)"
        ],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Fertig", "Abgebrochen"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      agent_ref = Process.monitor(agent_pid)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Abbruch (AI)",
        title: "Abort work",
        description: "User canceled the workflow",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      assert_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
      assert_receive {:memory_tracker_state_update, ^issue_id, "Abgebrochen"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "cancel issue from polling cleans workspace and moves issue to Abgebrochen without dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-poll-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-cancel-poll"
    issue_identifier = "MT-556-P"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: [
          "Todo (AI)",
          "In Arbeit (AI)",
          "Review (AI)",
          "Abbruch (AI)"
        ],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Fertig", "Abgebrochen"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Abbruch (AI)",
        title: "Abort idle work",
        description: "Workspace should be cleaned without dispatch",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :CancelPollingOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      File.mkdir_p!(Path.join(test_root, issue_identifier))

      send(pid, :tick)
      assert_receive {:memory_tracker_state_update, ^issue_id, "Abgebrochen"}, 1_000
      Process.sleep(100)

      refute File.exists?(Path.join(test_root, issue_identifier))
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo (AI)"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Arbeit (AI)",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Arbeit (AI)"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Arbeit (AI)",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Arbeit (AI)",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 250, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_000, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp review_handoff_test_recipient(parent, state_agent)
       when is_pid(parent) and is_pid(state_agent) do
    receive do
      {:memory_tracker_state_update, _issue_id, state_name} = message ->
        Agent.update(state_agent, fn _ -> state_name end)
        send(parent, message)
        review_handoff_test_recipient(parent, state_agent)

      _other ->
        review_handoff_test_recipient(parent, state_agent)
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder renders runtime local time context for workflow prompts" do
    workflow_prompt = "local={{ runtime.local_time }} tz={{ runtime.timezone }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698",
      title: "Local timestamps in workpad history",
      description: "Prompt should expose local runtime time",
      state: "Todo",
      url: "https://example.org/issues/MT-698",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert [_, local_time] = Regex.run(~r/local=([^ ]+)/, prompt)
    assert local_time =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/
    assert prompt =~ "tz="
  end

  test "prompt builder exposes session and workflow modes" do
    workflow_prompt =
      "session={{ runtime.session_mode }} workflow={{ runtime.workflow_mode }} automated={{ runtime.automated }} interactive={{ runtime.interactive }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698C",
      title: "Session mode",
      description: "Expose manual and automated modes",
      state: "Freigabe",
      url: "https://example.org/issues/MT-698C",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) ==
             "session=orchestrated workflow=interactive automated=false interactive=true"

    assert PromptBuilder.build_prompt(issue, session_mode: :manual) ==
             "session=manual workflow=interactive automated=false interactive=true"
  end

  test "prompt builder treats In Arbeit as interactive in orchestrated and manual sessions" do
    workflow_prompt = "{% if runtime.automated %}AUTO{% else %}INTERACTIVE{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698D",
      title: "In Arbeit bootstrap",
      description: "Session mode changes behavior",
      state: "In Arbeit",
      url: "https://example.org/issues/MT-698D",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "INTERACTIVE"
    assert PromptBuilder.build_prompt(issue, session_mode: :manual) == "INTERACTIVE"
  end

  test "prompt builder keeps AI states automated in manual sessions and falls back to orchestrated for unknown session modes" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ runtime.session_mode }} {{ runtime.workflow_mode }}")

    issue = %Issue{
      identifier: "MT-698DA",
      title: "AI state automation",
      description: "AI statuses stay automated",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-698DA",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue, session_mode: :manual) == "manual automated"
    assert PromptBuilder.build_prompt(issue, session_mode: :unexpected) == "orchestrated automated"
  end

  test "prompt builder treats missing issue states as interactive" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ runtime.workflow_mode }}")

    issue = %Issue{
      identifier: "MT-698DB",
      title: "Missing state",
      description: "Nil state should not force automation",
      state: nil,
      url: "https://example.org/issues/MT-698DB",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "interactive"
  end

  test "prompt builder can resolve an issue by identifier for manual sessions" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      prompt: "{{ issue.identifier }} {{ runtime.session_mode }} {{ runtime.workflow_mode }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698e",
        identifier: "MT-698E",
        title: "Resolve by identifier",
        description: "Manual prompt lookup",
        state: "Freigabe",
        url: "https://example.org/issues/MT-698E",
        labels: []
      }
    ])

    assert {:ok, "MT-698E orchestrated interactive"} =
             PromptBuilder.build_prompt_for_issue_identifier("MT-698E")

    assert {:ok, "MT-698E manual interactive"} =
             PromptBuilder.build_prompt_for_issue_identifier("MT-698E", session_mode: :manual)

    assert {:error, {:issue_not_found, "MISSING-1"}} =
             PromptBuilder.build_prompt_for_issue_identifier("MISSING-1", session_mode: :manual)
  end

  test "script support loads env files from the project root for manual prompts" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    project_root = Path.join(System.tmp_dir!(), "sym-codex-project-root-#{System.unique_integer([:positive])}")
    interactive_workflow_path = Path.join(project_root, "WORKFLOW_INTERACTIVE.md")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)
    File.write!(Path.join(project_root, ".env"), "LINEAR_API_KEY=project-root-key\n")
    File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: "$LINEAR_API_KEY",
      prompt: "{{ issue.identifier }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698f",
        identifier: "MT-698F",
        title: "External env directory",
        description: "Manual prompt should load env files from project root",
        state: "Freigabe",
        url: "https://example.org/issues/MT-698F",
        labels: []
      }
    ])

    assert {:ok, "interactive=MT-698F"} =
             ScriptSupport.manual_prompt(
               Workflow.workflow_file_path(),
               interactive_workflow_path,
               "MT-698F",
               project_root
             )

    assert Config.settings!().tracker.api_key == "project-root-key"
  end

  test "script support resolves workspace root after loading project env files" do
    previous_custom_root = System.get_env("SYMP_SCRIPT_WORKSPACE_ROOT")

    project_root =
      Path.join(System.tmp_dir!(), "sym-codex-workspace-root-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env("SYMP_SCRIPT_WORKSPACE_ROOT", previous_custom_root)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)
    File.write!(Path.join(project_root, ".env"), "SYMP_SCRIPT_WORKSPACE_ROOT=external-worktrees\n")
    System.delete_env("SYMP_SCRIPT_WORKSPACE_ROOT")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: "$SYMP_SCRIPT_WORKSPACE_ROOT"
    )

    assert {:ok, "external-worktrees"} =
             ScriptSupport.workspace_root(Workflow.workflow_file_path(), project_root)
  end

  test "prompt builder uses trimmed TZ environment values in runtime context" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.put_env("TZ", "  Europe/Paris  ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698A",
      title: "Trim timezone",
      description: "Prompt should trim TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698A",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=Europe/Paris"
  end

  test "prompt builder falls back to system-local when TZ is blank" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.put_env("TZ", "   ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698B",
      title: "Blank timezone",
      description: "Prompt should handle blank TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698B",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=system-local"
  end

  test "prompt builder falls back to system-local when TZ is unset" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.delete_env("TZ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698BB",
      title: "Unset timezone",
      description: "Prompt should handle missing TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698BB",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=system-local"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and
           is_pid(Process.whereis(SymphonyElixir.Supervisor)) and
           is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    if is_pid(Process.whereis(SymphonyElixir.Supervisor)) do
      assert :ok =
               Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Arbeit (AI)",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~
             ~r/(You are working on a Linear (ticket|issue)|Du arbeitest an einem Linear-Ticket) `MT-616`/

    assert prompt =~ ~r/(Issue context|Ticket-Kontext):/
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ ~r/(Title|Titel): Use rich templates for WORKFLOW.md/
    assert prompt =~ ~r/(Current status|Aktueller Status): In Arbeit \(AI\)/
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"

    assert prompt =~
             ~r/(This is an unattended orchestration session\.|Dies ist eine unbeaufsichtigte Orchestrierungssitzung\.)/

    assert prompt =~
             ~r/(Only stop early for a true blocker|Stoppe nur bei einem echten Blocker frühzeitig)/

    assert prompt =~ ~r/(Local system time for this turn|Lokale Systemzeit für diesen Turn):/
    assert prompt =~ ~r/(local system time|lokale Systemzeit)/
    assert prompt =~ ~r/(keine UTC- oder `Z`-Zeitstempel|do not use UTC or `Z` timestamps)/

    assert prompt =~ ~s("next steps for user")
    assert prompt =~ ".codex/skills/symphony-planning/SKILL.md"
    assert prompt =~ ".codex/skills/symphony-review/SKILL.md"
    assert prompt =~ ".codex/skills/symphony-workpad/SKILL.md"
    assert prompt =~ ".codex/skills/symphony-land/SKILL.md"
    assert prompt =~ "`gh pr merge`"
    assert prompt =~ ~r/(Continuation context|Fortsetzungskontext):/
    assert prompt =~ ~r/(retry attempt #2|Wiederholungsversuch Nr\. 2)/
  end

  test "in-repo WORKFLOW_INTERACTIVE.md renders planning and workpad skill guidance" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    original_workflow_path = Workflow.workflow_file_path()
    interactive_workflow_path = Path.expand("../../WORKFLOW_INTERACTIVE.md", __DIR__)
    project_root = Path.join(System.tmp_dir!(), "interactive-workflow-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      prompt: "{{ issue.identifier }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698g",
        identifier: "MT-698G",
        title: "Interactive workpad skill",
        description: "Manual prompt should mention workpad handling",
        state: "Freigabe",
        url: "https://example.org/issues/MT-698G",
        labels: []
      }
    ])

    assert {:ok, prompt} =
             ScriptSupport.manual_prompt(
               Workflow.workflow_file_path(),
               interactive_workflow_path,
               "MT-698G",
               project_root
             )

    assert prompt =~ "symphony-linear"
    assert prompt =~ "symphony-planning"
    assert prompt =~ "symphony-workpad"
    assert prompt =~ "Beginne nicht sofort mit der Ausführung"
    assert prompt =~ "Statuslogik"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Fertig"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner ignores In Arbeit without creating a workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      File.write!(Path.join(source_repo, "README.md"), "bootstrap\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'touch #{codex_stamp}'"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-bootstrap-1",
        identifier: "MT-BOOT",
        title: "Bootstrap only",
        description: "Prepare worktree and workpad",
        state: "In Arbeit",
        url: "https://example.org/issues/MT-BOOT",
        labels: ["backend"]
      }

      assert :ok =
               File.cd!(source_repo, fn ->
                 AgentRunner.run(issue)
               end)

      workspace = Path.join(workspace_root, "MT-BOOT")

      refute File.dir?(workspace)

      assert {worktree_list, 0} =
               System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"], stderr_to_stdout: true)

      refute worktree_list =~ workspace
      refute_receive {:memory_tracker_branch_update, "issue-bootstrap-1", _branch}, 100
      refute_receive {:memory_tracker_comment, "issue-bootstrap-1", _body}, 100
      refute File.exists?(codex_stamp)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Arbeit (AI)"
          else
            "Fertig"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner syncs the current workspace branch name to the tracker before running Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-branch-sync-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-branch-sync"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-branch-sync"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        workspace="$PWD"
        cd "$(dirname "$workspace")"
        rm -rf "$workspace"
        git -C "#{template_repo}" worktree add -b "symphony/MT-BRANCH-SYNC" "$workspace" main
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-branch-sync",
             identifier: "MT-BRANCH-SYNC",
             title: "Branch sync",
             description: "Sync tracker branch name from workspace",
             state: "Freigabe"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-branch-sync",
        identifier: "MT-BRANCH-SYNC",
        title: "Branch sync",
        description: "Sync tracker branch name from workspace",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-BRANCH-SYNC",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_branch_update, "issue-branch-sync", "symphony/MT-BRANCH-SYNC"}
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves PreReview (AI) issues to Freigabe after a clean prereview turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-prereview-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-prereview"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-prereview"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "PreReview (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-prereview-handoff",
             identifier: "MT-PREREVIEW",
             title: "PreReview handoff",
             description: "Advance after clean prereview turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-prereview-handoff",
        identifier: "MT-PREREVIEW",
        title: "PreReview handoff",
        description: "Advance after clean prereview turn",
        state: "PreReview (AI)",
        url: "https://example.org/issues/MT-PREREVIEW",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-prereview-handoff", "Freigabe"}
      assert "Freigabe" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Review (AI) issues to Test (AI) after a clean review turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-handoff",
             identifier: "MT-REVIEW",
             title: "Review handoff",
             description: "Advance after clean review turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-handoff",
        identifier: "MT-REVIEW",
        title: "Review handoff",
        description: "Advance after clean review turn",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-handoff", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Merge (AI) issues to Review after a clean merge turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-clean"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-clean"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-clean-handoff",
             identifier: "MT-MERGE-CLEAN",
             title: "Merge handoff clean",
             description: "Advance to review after a clean merge turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-clean-handoff",
        identifier: "MT-MERGE-CLEAN",
        title: "Merge handoff clean",
        description: "Advance to review after a clean merge turn",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-CLEAN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-clean-handoff", "Review"}
      assert "Review" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Test (AI) issues to Merge (AI) after a clean test turn without code changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-merge-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-clean"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-clean"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-clean-handoff",
             identifier: "MT-TEST-CLEAN",
             title: "Test handoff clean",
             description: "Advance to merge when tests need no fixes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-clean-handoff",
        identifier: "MT-TEST-CLEAN",
        title: "Test handoff clean",
        description: "Advance to merge when tests need no fixes",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-CLEAN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-clean-handoff", "Merge (AI)"}
      assert "Merge (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Test (AI) issues back to Freigabe after a clean test turn with code changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-fix"}}}'
            ;;
          4)
            printf '# fixed during test\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-fix"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-fix-handoff",
             identifier: "MT-TEST-FIX",
             title: "Test handoff with fix",
             description: "Return to review when tests required a fix",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-fix-handoff",
        identifier: "MT-TEST-FIX",
        title: "Test handoff with fix",
        description: "Return to review when tests required a fix",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-FIX",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-fix-handoff", "Freigabe"}
      assert "Freigabe" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Test (AI) issues back to Freigabe before running Codex when the workspace is dirty" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TEST-DIRTY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RAN\\n' >> "$trace_file"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-dirty"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-dirty"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-dirty-preflight",
             identifier: "MT-TEST-DIRTY",
             title: "Test preflight dirty workspace",
             description: "Return to review before testing when manual commit is missing",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-dirty-preflight",
        identifier: "MT-TEST-DIRTY",
        title: "Test preflight dirty workspace",
        description: "Return to review before testing when manual commit is missing",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-dirty-preflight", "Freigabe"}
      assert "Freigabe" == Agent.get(state_agent, & &1)
      refute File.exists?(trace_file)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Merge (AI) issues back to Freigabe before running Codex when the workspace is dirty" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MERGE-DIRTY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RAN\\n' >> "$trace_file"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-dirty"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-dirty"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-dirty-preflight",
             identifier: "MT-MERGE-DIRTY",
             title: "Merge preflight dirty workspace",
             description: "Return to review before merge when manual commit is missing",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-dirty-preflight",
        identifier: "MT-MERGE-DIRTY",
        title: "Merge preflight dirty workspace",
        description: "Return to review before merge when manual commit is missing",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-dirty-preflight", "Freigabe"}
      assert "Freigabe" == Agent.get(state_agent, & &1)
      refute File.exists?(trace_file)
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Arbeit (AI)"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
