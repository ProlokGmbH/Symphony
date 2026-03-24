defmodule SymphonyElixir.EnvFileTest do
  use ExUnit.Case

  alias SymphonyElixir.EnvFile

  test "loads .env and lets .env.local override repo defaults" do
    workflow_root = temp_workflow_root("load-order")
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
      File.rm_rf(workflow_root)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_ASSIGNEE")

    File.write!(Path.join(workflow_root, ".env"), "LINEAR_API_KEY=shared-key\nLINEAR_ASSIGNEE=team@example.com\n")
    File.write!(Path.join(workflow_root, ".env.local"), "LINEAR_ASSIGNEE=dev@example.com\n")

    assert :ok = EnvFile.load(workflow_root)
    assert System.get_env("LINEAR_API_KEY") == "shared-key"
    assert System.get_env("LINEAR_ASSIGNEE") == "dev@example.com"
  end

  test "preserves externally provided env vars over .env files" do
    workflow_root = temp_workflow_root("preserve-system-env")
    previous_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      File.rm_rf(workflow_root)
    end)

    System.put_env("LINEAR_API_KEY", "shell-key")
    File.write!(Path.join(workflow_root, ".env"), "LINEAR_API_KEY=repo-key\n")
    File.write!(Path.join(workflow_root, ".env.local"), "LINEAR_API_KEY=local-key\n")

    assert :ok = EnvFile.load(workflow_root)
    assert System.get_env("LINEAR_API_KEY") == "shell-key"
  end

  test "supports quoted values and comments" do
    workflow_root = temp_workflow_root("quoted-values")
    previous_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
      File.rm_rf(workflow_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")

    File.write!(
      Path.join(workflow_root, ".env"),
      ~s(LINEAR_ASSIGNEE="Dev Example <dev@example.com>" # local owner\n)
    )

    assert :ok = EnvFile.load(workflow_root)
    assert System.get_env("LINEAR_ASSIGNEE") == "Dev Example <dev@example.com>"
  end

  test "returns a clear error for invalid lines" do
    workflow_root = temp_workflow_root("invalid-line")

    on_exit(fn ->
      File.rm_rf(workflow_root)
    end)

    File.write!(Path.join(workflow_root, ".env"), "LINEAR_API_KEY\n")

    assert {:error, {:invalid_env_file, path, 1, :missing_assignment}} = EnvFile.load(workflow_root)
    assert path == Path.join(workflow_root, ".env")
  end

  defp temp_workflow_root(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-env-file-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
