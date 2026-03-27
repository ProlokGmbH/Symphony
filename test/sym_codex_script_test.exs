defmodule SymCodexScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../sym-codex", __DIR__)

  test "sym-codex reaches codex when invoked directly from the script repository" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(Path.join(repo_dir, "sym-codex"), bin_dir)
    assert output =~ "codex-stub"
  end

  test "sym-codex derives the issue identifier from the current worktree path" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, [],
               cd: worktree,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
  end

  test "sym-codex follows a symlink back to the script repository" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    link_dir = Path.join(System.tmp_dir!(), "sym-codex-link-#{System.unique_integer([:positive])}")
    link_path = Path.join(link_dir, "sym-codex")

    File.mkdir_p!(link_dir)
    File.ln_s!(Path.join(repo_dir, "sym-codex"), link_path)

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(link_dir)
    end)

    assert {output, 0} = run_script(link_path, bin_dir)
    assert output =~ "codex-stub"
  end

  test "sym-codex help omits the sourced invocation line" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["--help"])
    assert output =~ "Usage:"
    refute output =~ "source sym-codex"
  end

  defp build_script_fixture! do
    repo_dir =
      Path.join(System.tmp_dir!(), "sym-codex-script-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(System.tmp_dir!(), "sym-codex-bin-#{System.unique_integer([:positive])}")
    codex_path = Path.join(bin_dir, "codex")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(bin_dir)
    File.cp!(@script_source, Path.join(repo_dir, "sym-codex"))
    File.write!(codex_path, "#!/usr/bin/env bash\nprintf 'codex-stub pwd=%s args=%s\\n' \"$PWD\" \"$*\"\n")
    File.chmod!(codex_path, 0o755)
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "")
    File.write!(Path.join(repo_dir, "mix.exs"), "")

    %{repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp build_script_worktree_fixture!(issue_identifier) do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    workspace_root = Path.join(System.tmp_dir!(), "sym-codex-worktrees-#{System.unique_integer([:positive])}")
    worktree = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(workspace_root)

    git_cmd!(repo_dir, ["init", "-b", "main"])
    git_cmd!(repo_dir, ["config", "user.name", "SymCodex Script Test"])
    git_cmd!(repo_dir, ["config", "user.email", "sym-codex-script-test@example.com"])
    git_cmd!(repo_dir, ["add", "."])
    git_cmd!(repo_dir, ["commit", "-m", "Initial commit"])
    git_cmd!(repo_dir, ["worktree", "add", "-b", "symphony/#{issue_identifier}", worktree, "HEAD"])

    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree}
  end

  defp run_script(script_path, bin_dir, args \\ ["--observer"], opts \\ []) do
    env = [{"PATH", "#{bin_dir}:#{System.get_env("PATH")}"}] ++ Keyword.get(opts, :env, [])
    system_opts = [env: env, stderr_to_stdout: true]
    system_opts = maybe_put_cd(system_opts, Keyword.get(opts, :cd))

    System.cmd(
      "bash",
      [script_path | args],
      system_opts
    )
  end

  defp git_cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_, 0} = success -> success
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: Keyword.put(opts, :cd, cd)
end
