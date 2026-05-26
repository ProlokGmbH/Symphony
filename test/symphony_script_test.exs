defmodule SymphonyScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../symphony", __DIR__)

  test "symphony creates local bin symlinks for helper scripts" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    project_dir = Path.join(System.tmp_dir!(), "symphony-script-project-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(project_dir)
    end)

    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "WORKFLOW.md"), "---\n---\n")

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"], cd: project_dir)
    assert output =~ "symphony-stub args=--port 4001"
    assert output =~ "symphony-stub cwd=#{project_dir}"
    assert output =~ "symphony-stub codex_command=\n"
    assert output =~ "symphony-stub project_root=\n"
    assert output =~ "symphony-stub source_repo=\n"
    assert output =~ "symphony-stub workflow_file=\n"
    assert output =~ "symphony-stub worktrees_root=\n"
    assert File.read_link!(Path.join(home_dir, ".local/bin/sym-codex")) == Path.join(repo_dir, "sym-codex")
    assert File.read_link!(Path.join(home_dir, ".local/bin/sym-watch")) == Path.join(repo_dir, "sym-watch")
  end

  test "symphony runs autoupdate before launching escript" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    File.write!(Path.join(repo_dir, "autoupdate"), """
    #!/usr/bin/env bash
    printf 'autoupdate project=%s\\n' "$1"
    """)

    File.chmod!(Path.join(repo_dir, "autoupdate"), 0o755)

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"])

    assert output ==
             "autoupdate project=#{repo_dir}\n" <>
               "symphony-stub args=--port 4001\n"
  end

  test "symphony issue symlink points the local codex command at the matching issue symlink" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    project_dir = Path.join(System.tmp_dir!(), "symphony-script-issue-project-#{System.unique_integer([:positive])}")
    issue_link = Path.join(bin_dir, "symphony-PRO-351")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(project_dir)
    end)

    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "WORKFLOW.md"), "---\n---\n")
    File.ln_s!(Path.join(repo_dir, "symphony"), issue_link)

    assert {output, 0} = run_script_path(issue_link, home_dir, bin_dir, [], cd: project_dir)

    codex_issue_link = Path.join(home_dir, ".local/bin/sym-codex-PRO-351")
    assert File.read_link!(codex_issue_link) == Path.join(repo_dir, "sym-codex")
    assert output =~ "symphony-stub cwd=#{project_dir}"
    assert output =~ "symphony-stub codex_command=#{codex_issue_link} --observer"
    assert output =~ "symphony-stub project_root=\n"
    assert output =~ "symphony-stub workflow_file=\n"
  end

  test "symphony runs autoupdate before helper setup and launching escript" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    File.write!(Path.join(repo_dir, "autoupdate"), """
    #!/usr/bin/env bash
    printf 'autoupdate project=%s\\n' "$1"
    """)

    File.chmod!(Path.join(repo_dir, "autoupdate"), 0o755)

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"])

    assert String.starts_with?(output, "autoupdate project=#{repo_dir}\n")
    assert output =~ "symphony-stub args=--port 4001"
    assert File.read_link!(Path.join(home_dir, ".local/bin/sym-codex")) == Path.join(repo_dir, "sym-codex")
    assert File.read_link!(Path.join(home_dir, ".local/bin/sym-watch")) == Path.join(repo_dir, "sym-watch")
  end

  test "symphony rejects a non-symlink sym-watch local bin entry" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    user_bin_dir = Path.join(home_dir, ".local/bin")

    File.mkdir_p!(user_bin_dir)
    File.write!(Path.join(user_bin_dir, "sym-watch"), "not managed by symphony\n")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 1} = run_script(repo_dir, home_dir, bin_dir, [])
    assert output =~ "symphony: #{Path.join(user_bin_dir, "sym-watch")} exists and is not a symlink"
    refute output =~ "symphony-stub"
  end

  defp build_script_fixture! do
    repo_dir = Path.join(System.tmp_dir!(), "symphony-script-#{System.unique_integer([:positive])}")
    home_dir = Path.join(System.tmp_dir!(), "symphony-home-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(System.tmp_dir!(), "symphony-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "bin"))
    File.mkdir_p!(Path.join(repo_dir, ".codex/skills/symphony-test"))
    File.mkdir_p!(bin_dir)

    File.cp!(@script_source, Path.join(repo_dir, "symphony"))
    File.write!(Path.join(repo_dir, "sym-codex"), "#!/usr/bin/env bash\n")
    File.write!(Path.join(repo_dir, "sym-watch"), "#!/usr/bin/env bash\n")

    File.write!(Path.join(repo_dir, "bin/symphony"), """
    #!/usr/bin/env bash
    printf 'symphony-stub cwd=%s\\n' "$(pwd -P)"
    printf 'symphony-stub codex_command=%s\\n' "${SYMPHONY_CODEX_COMMAND:-}"
    printf 'symphony-stub project_root=%s\\n' "${SYMPHONY_PROJECT_ROOT:-}"
    printf 'symphony-stub source_repo=%s\\n' "${SYMPHONY_SOURCE_REPO:-}"
    printf 'symphony-stub workflow_file=%s\\n' "${SYMPHONY_WORKFLOW_FILE:-}"
    printf 'symphony-stub workflow_dir=%s\\n' "${SYMPHONY_WORKFLOW_DIR:-}"
    printf 'symphony-stub worktrees_root=%s\\n' "${SYMPHONY_PROJECT_WORKTREES_ROOT:-}"
    printf 'symphony-stub args=%s\\n' "$*"
    """)

    File.write!(Path.join(bin_dir, "mise"), """
    #!/usr/bin/env bash
    if [ "$1" = "env" ]; then
      exit 0
    fi

    printf 'unexpected mise args=%s\\n' "$*" >&2
    exit 1
    """)

    File.chmod!(Path.join(repo_dir, "symphony"), 0o755)
    File.chmod!(Path.join(repo_dir, "sym-codex"), 0o755)
    File.chmod!(Path.join(repo_dir, "sym-watch"), 0o755)
    File.chmod!(Path.join(repo_dir, "bin/symphony"), 0o755)
    File.chmod!(Path.join(bin_dir, "mise"), 0o755)

    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp run_script(repo_dir, home_dir, bin_dir, args, opts \\ []) do
    run_script_path(Path.join(repo_dir, "symphony"), home_dir, bin_dir, args, opts)
  end

  defp run_script_path(script_path, home_dir, bin_dir, args, opts) do
    cmd_opts =
      [
        env: [
          {"HOME", home_dir},
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"}
        ],
        stderr_to_stdout: true
      ]
      |> maybe_put_cd(Keyword.get(opts, :cd))

    System.cmd("bash", [script_path | args], cmd_opts)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: Keyword.put(opts, :cd, cd)
end
