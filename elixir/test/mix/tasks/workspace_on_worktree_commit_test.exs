defmodule Mix.Tasks.Workspace.OnWorktreeCommitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.OnWorktreeCommit

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.on_worktree_commit")
    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        OnWorktreeCommit.run(["--help"])
      end)

    assert output =~ "mix workspace.on_worktree_commit"
  end

  test "merges a worktree commit into the active source branch" do
    test_root = temp_root("workspace-on-worktree-commit")

    try do
      source_repo = Path.join(test_root, "source")
      workspace = Path.join([test_root, "worktrees", "MT-MERGE"])

      init_source_repo!(source_repo, "develop")
      add_worktree!(source_repo, workspace, "symphony/MT-MERGE")

      previous_head = current_head!(workspace)
      commit_file!(workspace, "README.md", "# merged into source\n", "worktree change")
      new_head = current_head!(workspace)

      output =
        capture_io(fn ->
          OnWorktreeCommit.run([
            "--source-repo",
            source_repo,
            "--workspace",
            workspace,
            "--branch",
            "symphony/MT-MERGE",
            "--old-head",
            previous_head,
            "--new-head",
            new_head
          ])
        end)

      assert output =~ "Merged #{new_head} into develop"
      assert File.read!(Path.join(source_repo, "README.md")) == "# merged into source\n"
      assert current_head!(source_repo) == new_head
    after
      File.rm_rf(test_root)
    end
  end

  test "aborts a failed merge and leaves the source repo reusable" do
    test_root = temp_root("workspace-on-worktree-conflict")

    try do
      source_repo = Path.join(test_root, "source")
      workspace = Path.join([test_root, "worktrees", "MT-CONFLICT"])

      init_source_repo!(source_repo, "develop")
      add_worktree!(source_repo, workspace, "symphony/MT-CONFLICT")

      commit_file!(workspace, "README.md", "# from worktree\n", "worktree change")
      worktree_head = current_head!(workspace)

      commit_file!(source_repo, "README.md", "# from source\n", "source change")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            OnWorktreeCommit.run([
              "--source-repo",
              source_repo,
              "--workspace",
              workspace,
              "--branch",
              "symphony/MT-CONFLICT",
              "--new-head",
              worktree_head
            ])
          end)
        end

      assert Exception.message(error) =~ "Failed to merge #{worktree_head} into develop"
      assert merge_in_progress?(source_repo) == false
      assert String.trim(git!(source_repo, ["status", "--porcelain"])) == ""
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

  defp merge_in_progress?(repo) when is_binary(repo) do
    case System.cmd("git", ["-C", repo, "rev-parse", "-q", "--verify", "MERGE_HEAD"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp git!(repo, args) when is_binary(repo) and is_list(args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with exit #{status}: #{output}")
    end
  end
end
