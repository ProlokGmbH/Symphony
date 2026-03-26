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

  defp build_script_fixture! do
    repo_dir =
      Path.join(System.tmp_dir!(), "sym-codex-script-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(System.tmp_dir!(), "sym-codex-bin-#{System.unique_integer([:positive])}")
    codex_path = Path.join(bin_dir, "codex")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(bin_dir)
    File.cp!(@script_source, Path.join(repo_dir, "sym-codex"))
    File.write!(codex_path, "#!/usr/bin/env bash\nprintf 'codex-stub %s\\n' \"$*\"\n")
    File.chmod!(codex_path, 0o755)
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "")
    File.write!(Path.join(repo_dir, "mix.exs"), "")

    %{repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp run_script(script_path, bin_dir) do
    System.cmd(
      "bash",
      [script_path, "--observer"],
      env: [{"PATH", "#{bin_dir}:#{System.get_env("PATH")}"}],
      stderr_to_stdout: true
    )
  end
end
