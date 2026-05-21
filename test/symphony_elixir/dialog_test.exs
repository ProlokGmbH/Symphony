defmodule SymphonyElixir.DialogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ScriptSupport
  alias SymphonyElixir.Dialog

  test "dialog helper builds first prompts, resumes user comments, and ignores completed answers" do
    dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }} active={{ runtime.active_repo_root }} workflow={{ runtime.workflow_file }}")

    issue = dialog_issue("issue-dialog-helper", "MT-D1")
    workspace = Path.join(System.tmp_dir!(), "dialog-helper-workspace")

    refute Dialog.state?(nil)

    assert {:ok, %{prompt: first_prompt, session_id: nil, include_session?: true}} =
             Dialog.next_request(issue, [], workspace)

    assert first_prompt =~ "dialog=MT-D1"
    assert first_prompt =~ "active=#{workspace}"
    assert first_prompt =~ "workflow=#{dialog_workflow_path}"

    comments = [
      %{body: "Follow-up question", created_at: ~U[2026-05-19 10:01:00Z]},
      %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
        created_at: ~U[2026-05-19 10:00:00Z]
      }
    ]

    assert {:ok, %{prompt: "Follow-up question", session_id: "thread-existing", include_session?: false}} =
             Dialog.next_request(issue, comments, workspace)

    completed_comments = [
      %{body: "Already handled question", created_at: ~U[2026-05-19 10:00:00Z]},
      %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nFinal answer",
        created_at: ~U[2026-05-19 10:01:00Z]
      }
    ]

    assert {:ok, :noop} = Dialog.next_request(issue, completed_comments, workspace)

    assert Dialog.format_answer_comment("### Antwort Symphony\n\nDone", "thread-new", true) ==
             "### Antwort Symphony\n\n[Session thread-new]\n\nDone\n"

    assert Dialog.answer_comment?(%{"body" => "### Antwort Symphony\n\nString key"})
    assert Dialog.answer_comment?("### Antwort Symphony\n\nRaw body")
    refute Dialog.answer_comment?(%{body: 123})
    refute Dialog.answer_comment?(nil)
  end

  test "dialog helper handles fallback answer messages and mixed comment shapes" do
    issue = dialog_issue("issue-dialog-shapes", "MT-DSHAPES")
    workspace = Path.join(System.tmp_dir!(), "dialog-shapes-workspace")
    write_dialog_workflow!("dialog={{ issue.identifier }}")

    comments = [
      %{"body" => "User after string timestamp", "createdAt" => "2026-05-19T10:02:00Z"},
      %{"body" => "### Antwort Symphony\n\n[Session thread-string]\n\nPrevious", "created_at" => "2026-05-19T10:01:00Z"},
      %{body: "", updated_at: ~U[2026-05-19 10:00:00Z]}
    ]

    assert {:ok, %{prompt: "User after string timestamp", session_id: "thread-string"}} =
             Dialog.next_request(issue, comments, workspace)

    comments_without_timestamps = [
      %{body: "### Antwort Symphony\n\n[Session thread-unsorted]\n\nPrevious"},
      %{body: "User without timestamps"}
    ]

    assert {:ok, %{prompt: "User without timestamps", session_id: "thread-unsorted"}} =
             Dialog.next_request(issue, comments_without_timestamps, workspace)

    comments_with_invalid_timestamp = [
      %{body: "### Antwort Symphony\n\n[Session thread-invalid]\n\nPrevious", created_at: "not-a-timestamp"},
      nil,
      %{body: "User after invalid timestamp"}
    ]

    assert {:ok, %{prompt: "User after invalid timestamp", session_id: "thread-invalid"}} =
             Dialog.next_request(issue, comments_with_invalid_timestamp, workspace)

    assert Dialog.final_answer_from_messages([
             %{"payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => "fallback answer"}}}}
           ]) == "fallback answer"

    assert Dialog.final_answer_from_messages([
             %{payload: %{method: "item/completed", params: %{item: %{type: "agentMessage", text: "atom answer", phase: "final_answer"}}}}
           ]) == "atom answer"

    assert is_nil(
             Dialog.final_answer_from_messages([
               %{payload: %{method: "item/completed", params: %{item: %{type: "agentMessage", text: "   "}}}}
             ])
           )

    assert is_nil(Dialog.final_answer_from_messages([%{payload: %{method: "other"}}]))
    assert is_nil(Dialog.final_answer_from_messages(["not a map"]))
  end

  test "default dialog workflow requires a related Linear relation for created implementation tickets" do
    workflow_path = Path.expand("../../WORKFLOW_DIALOG.md", __DIR__)
    assert {:ok, %{prompt_template: prompt_template}} = Workflow.load(workflow_path)

    issue = dialog_issue("issue-dialog-relation", "MT-DREL")

    prompt =
      PromptBuilder.build_prompt(issue,
        prompt_template: prompt_template,
        active_repo_root: "/tmp/project",
        source_repo_root: "/tmp/project",
        workflow_file: workflow_path
      )

    assert prompt =~ "Linear-Issue-ID: issue-dialog-relation"
    assert prompt =~ "issueRelationCreate"
    assert prompt =~ ~s(issueId: "issue-dialog-relation")
    assert prompt =~ "relatedIssueId"
    assert prompt =~ "type: related"
    assert prompt =~ "Related/relatedTo-Verknüpfung"
  end

  test "agent runner answers dialog issues without creating a git worktree or running hooks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-runner-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      hook_marker = Path.join(test_root, "hook-ran")

      File.mkdir_p!(test_root)
      write_fake_codex!(codex_binary, trace_file, "thread-dialog", "turn-dialog", "Dialog answer")
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "touch #{hook_marker}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-runner", "MT-DIALOG")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:worker_runtime_info, "issue-dialog-runner", %{workspace_path: dialog_workspace}}, 1_000
      assert dialog_workspace == File.cwd!()
      assert File.dir?(dialog_workspace)
      refute File.exists?(Path.join(workspace_root, ".dialog"))
      refute File.exists?(Path.join(workspace_root, "MT-DIALOG"))
      refute File.exists?(hook_marker)

      assert_receive {:memory_tracker_comment, "issue-dialog-runner", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Session thread-dialog]"
      assert body =~ "Dialog answer"

      trace = File.read!(trace_file)
      assert trace =~ "PWD:#{File.cwd!()}"
      assert trace =~ ~s("method":"thread/start")
      refute trace =~ ~s("method":"thread/resume")
      assert trace =~ "dialog prompt MT-DIALOG"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner resumes the stored dialog session for new user comments" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-resume-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)
      write_fake_codex!(codex_binary, trace_file, "thread-existing", "turn-resumed", "Resume answer")
      write_dialog_workflow!("first turn {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-resume", "MT-DRES")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-resume" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:memory_tracker_comment, "issue-dialog-resume", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Resume answer"
      refute body =~ "[Session"

      trace = File.read!(trace_file)
      assert trace =~ ~s("method":"thread/resume")
      assert trace =~ ~s("threadId":"thread-existing")
      assert trace =~ "What should we do next?"
      refute trace =~ ~s("method":"thread/start")
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "script support exposes dialog prompts and session ids without an implementation worktree" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-script-support-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      interactive_workflow_path = Path.join(test_root, "WORKFLOW_INTERACTIVE.md")

      File.mkdir_p!(Path.join(project_root, ".symphony"))
      File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")

      dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = dialog_issue("issue-dialog-script", "MT-DSCRIPT")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-script" => [
          %{body: "Follow-up from Linear", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-script]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      assert {:ok, %{prompt: "Follow-up from Linear", workflow_step: "Todo (Dialog-AI)", session_id: "thread-script"}} =
               ScriptSupport.manual_prompt_context(
                 Workflow.workflow_file_path(),
                 interactive_workflow_path,
                 dialog_workflow_path,
                 "MT-DSCRIPT",
                 project_root
               )

      refute File.exists?(Path.join(workspace_root, ".dialog"))
      refute File.exists?(Path.join(workspace_root, "MT-DSCRIPT"))
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "script support exposes dialog workflow step, dialog workspace, and no-op contexts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-script-noop-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_dialog_workflow_path = Application.get_env(:symphony_elixir, :dialog_workflow_file_path)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      interactive_workflow_path = Path.join(test_root, "WORKFLOW_INTERACTIVE.md")
      previous_dialog_path = Path.join(test_root, "previous-dialog.md")

      File.mkdir_p!(Path.join(project_root, ".symphony"))
      File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")
      File.write!(previous_dialog_path, "---\n---\nprevious\n")
      Application.put_env(:symphony_elixir, :dialog_workflow_file_path, previous_dialog_path)

      dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = dialog_issue("issue-dialog-noop", "MT-DNOOP")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-noop" => [
          %{body: "Question already handled", created_at: ~U[2026-05-19 10:00:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-noop]\n\nAlready answered",
            created_at: ~U[2026-05-19 10:01:00Z]
          }
        ]
      })

      assert {:ok, "Todo (Dialog-AI)"} =
               ScriptSupport.workflow_step(Workflow.workflow_file_path(), "MT-DNOOP", project_root)

      assert {:ok, workspace} =
               ScriptSupport.dialog_workspace(Workflow.workflow_file_path(), "MT-DNOOP", project_root)

      assert workspace == Path.expand(project_root)
      refute File.exists?(Path.join(workspace_root, ".dialog"))

      assert {:ok, %{prompt: "", workflow_step: "Todo (Dialog-AI)", session_id: "thread-noop"}} =
               ScriptSupport.manual_prompt_context(
                 Workflow.workflow_file_path(),
                 interactive_workflow_path,
                 dialog_workflow_path,
                 "MT-DNOOP",
                 project_root
               )

      assert Application.get_env(:symphony_elixir, :dialog_workflow_file_path) == previous_dialog_path
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:dialog_workflow_file_path, previous_dialog_workflow_path)
      File.rm_rf(test_root)
    end
  end

  test "memory tracker normalizes comment maps and non-comment values" do
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-memory-comments" => [
          %{"id" => "comment-1", "body" => "string-key body", "createdAt" => "2026-05-19T10:00:00Z"},
          123
        ]
      })

      assert {:ok,
              [
                %{id: "comment-1", body: "string-key body", created_at: "2026-05-19T10:00:00Z", updated_at: nil},
                %{body: ""}
              ]} = Tracker.fetch_issue_comments("issue-memory-comments")

      assert {:ok, ["string-key body", ""]} = Tracker.fetch_issue_comment_bodies("issue-memory-comments")
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
    end
  end

  test "orchestrator treats dialog issues as active outside the workflow status table" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo (AI)"],
      tracker_terminal_states: ["Fertig"]
    )

    issue = dialog_issue("issue-dialog-active", "MT-DACTIVE")

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "orchestrator rechecks completed dialog issues because new comments may not update the issue timestamp" do
    completed_at = ~U[2026-05-21 09:50:44Z]
    issue = %{dialog_issue("issue-dialog-comment", "MT-DCOMMENT") | updated_at: completed_at}

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      completed_states: %{"issue-dialog-comment" => {"todo (dialog-ai)", DateTime.to_iso8601(completed_at)}},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  defp write_dialog_workflow!(prompt) when is_binary(prompt) do
    path =
      Workflow.workflow_file_path()
      |> Path.dirname()
      |> Path.join("WORKFLOW_DIALOG.md")

    File.write!(path, "---\n---\n#{prompt}\n")
    path
  end

  defp dialog_issue(issue_id, identifier) do
    %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Dialog issue",
      description: "Discuss the idea before implementation.",
      state: Dialog.state_name(),
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp write_fake_codex!(codex_binary, trace_file, thread_id, turn_id, answer) do
    escaped_thread_id = Jason.encode!(thread_id)
    escaped_turn_id = Jason.encode!(turn_id)
    escaped_answer = Jason.encode!(answer)

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    printf 'PWD:%s\\n' "$(pwd)" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":#{escaped_thread_id}}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":#{escaped_turn_id}}}}'
          ;;
        4)
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":#{escaped_answer}}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
