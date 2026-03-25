defmodule SymphonyElixir.WorktreeCommitMonitorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Workflow, WorktreeCommitMonitor}

  setup do
    original_cwd = File.cwd!()
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      File.cd!(original_cwd)
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    :ok
  end

  test "runs on_worktree_commit when a managed worktree receives a new commit" do
    test_root = temp_root("worktree-commit-monitor")
    project_dir = File.cwd!()

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = source_repo <> "-worktrees"
      workflow_file = Path.join(test_root, "WORKFLOW.md")
      hook_log = Path.join(test_root, "hook.log")
      workspace = Path.join(workspace_root, "MT-COMMIT")

      init_source_repo!(source_repo, "develop")
      add_worktree!(source_repo, workspace, "symphony/MT-COMMIT")

      write_workflow_file!(workflow_file,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_on_worktree_commit: "printf '%s|%s|%s|%s\\n' \"$SYMPHONY_WORKSPACE\" \"$SYMPHONY_BRANCH_NAME\" \"$SYMPHONY_PREV_HEAD_SHA\" \"$SYMPHONY_HEAD_SHA\" >> \"#{hook_log}\""
      )

      Workflow.set_workflow_file_path(workflow_file)
      File.cd!(source_repo)

      assert :ok = WorktreeCommitMonitor.run()
      refute File.exists?(hook_log)

      previous_head = current_head!(workspace)
      commit_file!(workspace, "README.md", "# updated from worktree\n", "worktree commit")
      current_head = current_head!(workspace)

      assert :ok = WorktreeCommitMonitor.run()
      assert File.read!(hook_log) == "#{workspace}|symphony/MT-COMMIT|#{previous_head}|#{current_head}\n"
      assert File.cwd!() == source_repo
      assert project_dir != source_repo
    after
      File.rm_rf(test_root)
    end
  end

  test "retries on_worktree_commit until the hook succeeds" do
    test_root = temp_root("worktree-commit-retry")

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = source_repo <> "-worktrees"
      workflow_file = Path.join(test_root, "WORKFLOW.md")
      hook_log = Path.join(test_root, "retry.log")
      blocker = Path.join(test_root, "block")
      workspace = Path.join(workspace_root, "MT-RETRY")

      init_source_repo!(source_repo, "develop")
      add_worktree!(source_repo, workspace, "symphony/MT-RETRY")

      write_workflow_file!(workflow_file,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_on_worktree_commit: "if [ -f \"#{blocker}\" ]; then exit 17; fi\nprintf '%s\\n' \"$SYMPHONY_HEAD_SHA\" >> \"#{hook_log}\""
      )

      Workflow.set_workflow_file_path(workflow_file)
      File.cd!(source_repo)

      assert :ok = WorktreeCommitMonitor.run()

      commit_file!(workspace, "README.md", "# retry path\n", "retry commit")
      pending_head = current_head!(workspace)
      File.write!(blocker, "block\n")

      assert :ok = WorktreeCommitMonitor.run()
      refute File.exists?(hook_log)

      File.rm!(blocker)

      assert :ok = WorktreeCommitMonitor.run()
      assert File.read!(hook_log) == "#{pending_head}\n"
    after
      File.rm_rf(test_root)
    end
  end

  defp temp_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp init_source_repo!(source_repo, branch) when is_binary(source_repo) and is_binary(branch) do
    File.mkdir_p!(source_repo)
    File.write!(Path.join(source_repo, "README.md"), "# initial\n")
    git!(source_repo, ["init", "-b", branch])
    git!(source_repo, ["config", "user.name", "Test User"])
    git!(source_repo, ["config", "user.email", "test@example.com"])
    git!(source_repo, ["add", "README.md"])
    git!(source_repo, ["commit", "-m", "initial"])
  end

  defp add_worktree!(source_repo, workspace, branch)
       when is_binary(source_repo) and is_binary(workspace) and is_binary(branch) do
    File.mkdir_p!(Path.dirname(workspace))
    git!(source_repo, ["worktree", "add", "-b", branch, workspace, "HEAD"])
  end

  defp commit_file!(repo, relative_path, content, message)
       when is_binary(repo) and is_binary(relative_path) and is_binary(content) and is_binary(message) do
    File.write!(Path.join(repo, relative_path), content)
    git!(repo, ["add", relative_path])
    git!(repo, ["commit", "-m", message])
  end

  defp current_head!(repo) when is_binary(repo) do
    repo
    |> git!(["rev-parse", "HEAD"])
    |> String.trim()
  end

  defp git!(repo, args) when is_binary(repo) and is_list(args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with exit #{status}: #{output}")
    end
  end
end
