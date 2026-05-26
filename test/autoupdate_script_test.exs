defmodule AutoupdateScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../autoupdate", __DIR__)

  test "exits quietly when upstream has no new commit" do
    %{root_dir: root_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {"", 0} = run_autoupdate(worktree_dir, "j\n", bin_dir, make_log)
    refute File.exists?(make_log)
  end

  test "declining an available update leaves the checkout unchanged" do
    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)
    old_head = git_output!(worktree_dir, ["rev-parse", "HEAD"])

    push_remote_commit!(seed_dir, "v2\n", "remote update")

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {output, 0} = run_autoupdate(worktree_dir, "n\n", bin_dir, make_log)

    assert output =~ "Neue Symphony Version verfügbar. Update ausführen j/n?"
    refute output =~ "Symphony Update läuft…"
    assert git_output!(worktree_dir, ["rev-parse", "HEAD"]) == old_head
    refute File.exists?(make_log)
  end

  test "accepted update pulls the new commit and runs make all" do
    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)

    push_remote_commit!(seed_dir, "v2\n", "remote update")
    remote_head = git_output!(seed_dir, ["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {output, 0} = run_autoupdate(worktree_dir, "j\n", bin_dir, make_log)

    assert output =~ "Neue Symphony Version verfügbar. Update ausführen j/n?"
    assert output =~ "Symphony Update läuft…"
    assert git_output!(worktree_dir, ["rev-parse", "HEAD"]) == remote_head
    assert File.read!(make_log) == "make args=all\n"
  end

  defp build_git_fixture! do
    root_dir = Path.join(System.tmp_dir!(), "symphony-autoupdate-#{System.unique_integer([:positive])}")
    remote_dir = Path.join(root_dir, "remote.git")
    seed_dir = Path.join(root_dir, "seed")
    worktree_dir = Path.join(root_dir, "worktree")

    File.mkdir_p!(root_dir)

    git!(root_dir, ["init", "--bare", remote_dir])
    git!(root_dir, ["clone", remote_dir, seed_dir])
    configure_user!(seed_dir)

    File.write!(Path.join(seed_dir, "README.md"), "v1\n")
    git!(seed_dir, ["add", "README.md"])
    git!(seed_dir, ["commit", "-m", "initial"])
    git!(seed_dir, ["branch", "-M", "main"])
    git!(seed_dir, ["push", "-u", "origin", "main"])
    git!(root_dir, ["--git-dir", remote_dir, "symbolic-ref", "HEAD", "refs/heads/main"])

    git!(root_dir, ["clone", remote_dir, worktree_dir])
    configure_user!(worktree_dir)

    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir}
  end

  defp build_make_fixture!(root_dir) do
    bin_dir = Path.join(root_dir, "bin")
    make_log = Path.join(root_dir, "make.log")

    File.mkdir_p!(bin_dir)

    File.write!(Path.join(bin_dir, "make"), """
    #!/usr/bin/env bash
    printf 'make args=%s\\n' "$*" >> "$MAKE_LOG"
    """)

    File.chmod!(Path.join(bin_dir, "make"), 0o755)

    %{bin_dir: bin_dir, make_log: make_log}
  end

  defp push_remote_commit!(repo_dir, contents, message) do
    File.write!(Path.join(repo_dir, "README.md"), contents)
    git!(repo_dir, ["add", "README.md"])
    git!(repo_dir, ["commit", "-m", message])
    git!(repo_dir, ["push", "origin", "main"])
  end

  defp configure_user!(repo_dir) do
    git!(repo_dir, ["config", "user.email", "symphony@example.com"])
    git!(repo_dir, ["config", "user.name", "Symphony Test"])
  end

  defp run_autoupdate(repo_dir, input, bin_dir, make_log) do
    System.cmd(
      "bash",
      ["-c", "printf '%s' \"$AUTOUPDATE_INPUT\" | \"$AUTOUPDATE_SCRIPT\" \"$SYMPHONY_REPO\""],
      env: [
        {"AUTOUPDATE_INPUT", input},
        {"AUTOUPDATE_SCRIPT", @script_source},
        {"SYMPHONY_REPO", repo_dir},
        {"MAKE_LOG", make_log},
        {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"}
      ],
      stderr_to_stdout: true
    )
  end

  defp git!(repo_dir, args) do
    assert {_output, 0} = System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    :ok
  end

  defp git_output!(repo_dir, args) do
    assert {output, 0} = System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
