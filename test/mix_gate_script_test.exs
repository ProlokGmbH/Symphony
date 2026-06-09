defmodule MixGateScriptTest do
  use ExUnit.Case

  @script_path Path.expand("../scripts/mix-gate", __DIR__)
  @repo_root Path.expand("..", __DIR__)

  test "mix-gate clears Symphony runtime env and trusts mise.toml for the process" do
    bin_dir =
      Path.join(System.tmp_dir!(), "mix-gate-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)

    File.write!(Path.join(bin_dir, "mise"), """
    #!/usr/bin/env bash
    printf 'args=%s\\n' "$*"
    printf 'trusted=%s\\n' "${MISE_TRUSTED_CONFIG_PATHS:-}"
    printf 'workflow=%s\\n' "${SYMPHONY_WORKFLOW_FILE-unset}"
    printf 'workflow_dir=%s\\n' "${SYMPHONY_WORKFLOW_DIR-unset}"
    printf 'source=%s\\n' "${SYMPHONY_SOURCE_REPO-unset}"
    printf 'project=%s\\n' "${SYMPHONY_PROJECT_ROOT-unset}"
    """)

    File.chmod!(Path.join(bin_dir, "mise"), 0o755)

    on_exit(fn -> File.rm_rf(bin_dir) end)

    env =
      [
        {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
        {"MISE_TRUSTED_CONFIG_PATHS", "/tmp/existing-trust"},
        {"SYMPHONY_WORKFLOW_FILE", "/tmp/wrong/WORKFLOW.md"},
        {"SYMPHONY_WORKFLOW_DIR", "/tmp/wrong"},
        {"SYMPHONY_SOURCE_REPO", "/tmp/wrong-source"},
        {"SYMPHONY_PROJECT_ROOT", "/tmp/wrong-project"}
      ]

    assert {output, 0} = System.cmd(@script_path, ["format", "--check-formatted"], env: env, stderr_to_stdout: true)

    assert output =~ "args=x -- mix format --check-formatted"
    assert output =~ "trusted=#{Path.join(@repo_root, "mise.toml")}:/tmp/existing-trust"
    assert output =~ "workflow=unset"
    assert output =~ "workflow_dir=unset"
    assert output =~ "source=unset"
    assert output =~ "project=unset"
  end
end
