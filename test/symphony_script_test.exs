defmodule SymphonyScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../symphony", __DIR__)

  test "symphony creates local bin symlinks for helper scripts" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"])
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

  defp run_script(repo_dir, home_dir, bin_dir, args) do
    System.cmd("bash", [Path.join(repo_dir, "symphony") | args],
      env: [
        {"HOME", home_dir},
        {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"}
      ],
      stderr_to_stdout: true
    )
  end
end
