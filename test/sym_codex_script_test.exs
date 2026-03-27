defmodule SymCodexScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../sym-codex", __DIR__)
  @mcp_script_source Path.expand("../sym-codex-mcp", __DIR__)
  @interactive_workflow_source Path.expand("../WORKFLOW_INTERACTIVE.md", __DIR__)

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

  test "sym-codex configures a repo-local MCP server for direct execution" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"], env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}])

    assert output =~ ~s(mcp_servers.symphony_linear.command="#{repo_dir}/sym-codex-mcp")
    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{repo_dir}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{repo_dir}/WORKFLOW.md")
    assert output =~ "manual-prompt-for-PRO-49"
  end

  test "sym-codex prefers the current Symphony worktree for MCP server wiring" do
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

    assert output =~ ~s(mcp_servers.symphony_linear.command="#{worktree}/sym-codex-mcp")
    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{worktree}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{worktree}/WORKFLOW.md")
    assert output =~ "manual-prompt-for-PRO-49"
  end

  test "sym-codex resolves worktrees from the local project root when launched from another repo" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-28"], cd: project_root)

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
  end

  test "sym-codex infers the issue identifier from an external project worktree" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, [], cd: worktree)

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
  end

  test "sourced sym-codex activates the repo venv in the current shell" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    command =
      ~s|. "#{Path.join(repo_dir, "sym-codex")}" PRO-49; printf 'after pwd=%s venv=%s codex=%s\\n' "$PWD" "${VIRTUAL_ENV:-}" "$(command -v codex)"|

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        cd: repo_dir,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
    assert output =~ "venv=#{Path.join(repo_dir, ".venv")}"
    assert output =~ "codex=#{Path.join(repo_dir, ".venv/bin/codex")}"
  end

  test "sourced sym-codex keeps repo python ahead in login shells spawned afterwards" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: _worktree} =
      build_script_worktree_fixture!("PRO-49")

    fake_home =
      Path.join(System.tmp_dir!(), "sym-codex-home-#{System.unique_integer([:positive])}")

    fake_user_bin = Path.join(fake_home, ".local/bin")
    fake_user_python = Path.join(fake_user_bin, "python")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
      File.rm_rf(fake_home)
    end)

    File.mkdir_p!(fake_user_bin)

    File.write!(Path.join(fake_home, ".profile"), """
    PATH="$HOME/.local/bin:$PATH"
    export PATH
    """)

    File.write!(fake_user_python, """
    #!/usr/bin/env bash
    printf 'user-python\\n'
    """)

    File.chmod!(fake_user_python, 0o755)

    command =
      ~s|. "#{Path.join(repo_dir, "sym-codex")}" PRO-49; HOME="#{fake_home}" bash -lc 'printf "python=%s\\nvenv=%s\\nbash_env=%s\\n" "$(command -v python)" "${VIRTUAL_ENV:-}" "${BASH_ENV:-}"'|

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        cd: repo_dir,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "python=#{Path.join(repo_dir, ".venv/bin/python")}"
    assert output =~ "venv=#{Path.join(repo_dir, ".venv")}"
    assert output =~ "bash_env=#{Path.join(repo_dir, ".venv/bin/activate")}"
  end

  test "sym-codex prefers a worktree-local venv over the script-repo venv" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    create_venv_fixture!(worktree, "workspace")

    {output, 0} =
      run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
        env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
      )

    assert output =~ "venv=#{Path.join(worktree, ".venv")}"
  end

  test "sym-codex prefers the project-root venv over worktree and script-repo venvs" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      workspace_root: _workspace_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    create_venv_fixture!(project_root, "project")
    create_venv_fixture!(worktree, "workspace")

    {output, 0} =
      run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-28"], cd: worktree)

    assert output =~ "venv=#{Path.join(project_root, ".venv")}"
  end

  defp build_script_fixture! do
    repo_dir =
      Path.join(System.tmp_dir!(), "sym-codex-script-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(System.tmp_dir!(), "sym-codex-bin-#{System.unique_integer([:positive])}")
    codex_path = Path.join(bin_dir, "codex")
    mix_path = Path.join(bin_dir, "mix")
    mise_path = Path.join(bin_dir, "mise")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(bin_dir)
    File.cp!(@script_source, Path.join(repo_dir, "sym-codex"))
    File.cp!(@mcp_script_source, Path.join(repo_dir, "sym-codex-mcp"))
    File.write!(codex_path, "#!/usr/bin/env bash\nprintf 'codex-stub pwd=%s args=%s\\n' \"$PWD\" \"$*\"\n")
    create_venv_fixture!(repo_dir, "repo")

    File.write!(mix_path, """
    #!/usr/bin/env bash
    if [ "$1" = "run" ] && [ "$2" = "--no-start" ] && [ "$3" = "-e" ]; then
      shift 4

      if [ "$1" = "--" ]; then
        shift
      fi

      case "$#" in
        1)
          printf '%s' "${SYMPHONY_PROJECT_WORKTREES_ROOT:-}"
          exit 0
          ;;
        3)
          printf 'manual-prompt-for-%s' "$3"
          exit 0
          ;;
      esac
    fi

    printf 'unexpected mix args=%s\\n' "$*" >&2
    exit 1
    """)

    File.write!(mise_path, "#!/usr/bin/env bash\nif [ \"$1\" = \"exec\" ] && [ \"$2\" = \"--\" ]; then\n  shift 2\n  exec \"$@\"\nfi\nprintf 'unexpected mise args=%s\\n' \"$*\" >&2\nexit 1\n")
    File.chmod!(codex_path, 0o755)
    File.chmod!(mix_path, 0o755)
    File.chmod!(mise_path, 0o755)
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "")
    File.cp!(@interactive_workflow_source, Path.join(repo_dir, "WORKFLOW_INTERACTIVE.md"))
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

  defp build_external_project_fixture!(issue_identifier) do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    test_root =
      Path.join(System.tmp_dir!(), "sym-codex-project-#{System.unique_integer([:positive])}")

    project_root = Path.join(test_root, "project")
    workspace_root = project_root <> "-worktrees"
    worktree = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(project_root)
    File.mkdir_p!(workspace_root)

    git_cmd!(project_root, ["init", "-b", "main"])
    git_cmd!(project_root, ["config", "user.name", "SymCodex External Project Test"])
    git_cmd!(project_root, ["config", "user.email", "sym-codex-external-project-test@example.com"])
    File.write!(Path.join(project_root, "README.md"), "project\n")
    git_cmd!(project_root, ["add", "README.md"])
    git_cmd!(project_root, ["commit", "-m", "Initial commit"])
    git_cmd!(project_root, ["worktree", "add", "-b", "symphony/#{issue_identifier}", worktree, "HEAD"])

    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      workspace_root: workspace_root,
      worktree: worktree
    }
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

  defp create_venv_fixture!(root, label) do
    venv_bin_dir = Path.join(root, ".venv/bin")
    venv_activate_path = Path.join(venv_bin_dir, "activate")
    venv_codex_path = Path.join(venv_bin_dir, "codex")
    venv_python_path = Path.join(venv_bin_dir, "python")

    File.mkdir_p!(venv_bin_dir)

    File.write!(venv_activate_path, """
    _sym_codex_venv_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    export VIRTUAL_ENV="$_sym_codex_venv_dir"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    """)

    File.write!(venv_codex_path, """
    #!/usr/bin/env bash
    printf 'codex-stub pwd=%s args=%s venv=%s label=#{label}\\n' "$PWD" "$*" "${VIRTUAL_ENV:-}"
    """)

    File.write!(venv_python_path, """
    #!/usr/bin/env bash
    printf '#{label}-python\\n'
    """)

    File.chmod!(venv_codex_path, 0o755)
    File.chmod!(venv_python_path, 0o755)
  end
end
