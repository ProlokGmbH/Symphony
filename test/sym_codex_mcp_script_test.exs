defmodule SymCodexMcpScriptTest do
  use ExUnit.Case

  @script_path Path.expand("../sym-codex-mcp", __DIR__)

  test "sym-codex-mcp serves initialize and tools/list over stdio" do
    source_repo = build_clean_source_repo!()
    workflow_file = Path.join(source_repo, "WORKFLOW.md")
    runtime_path = elixir_runtime_path!()

    input =
      [
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}),
        ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    input_file =
      Path.join(System.tmp_dir!(), "sym-codex-mcp-input-#{System.unique_integer([:positive])}.jsonl")

    File.write!(input_file, input)

    on_exit(fn ->
      File.rm(input_file)
      remove_clean_source_repo!(source_repo)
    end)

    {output, 0} =
      System.cmd(
        "bash",
        ["-lc", "cat \"$INPUT_FILE\" | \"$SCRIPT_PATH\""],
        env: [
          {"INPUT_FILE", input_file},
          {"PATH", runtime_path},
          {"SCRIPT_PATH", @script_path},
          {"SYMPHONY_SOURCE_REPO", source_repo},
          {"SYMPHONY_WORKFLOW_FILE", workflow_file}
        ],
        stderr_to_stdout: true
      )

    [initialize_line, tools_list_line] =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))

    initialize = Jason.decode!(initialize_line)
    tools_list = Jason.decode!(tools_list_line)

    assert initialize == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{
                 "name" => "symphony-linear",
                 "version" => "0.1.0"
               }
             }
           }

    assert get_in(tools_list, ["result", "tools"]) == [
             %{
               "name" => "linear_graphql",
               "description" => "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.\n",
               "inputSchema" => %{
                 "type" => "object",
                 "required" => ["query"],
                 "additionalProperties" => false,
                 "properties" => %{
                   "query" => %{
                     "type" => "string",
                     "description" => "GraphQL query or mutation document to execute against Linear."
                   },
                   "variables" => %{
                     "type" => ["object", "null"],
                     "description" => "Optional GraphQL variables object.",
                     "additionalProperties" => true
                   }
                 }
               }
             }
           ]
  end

  defp build_clean_source_repo! do
    source_repo =
      Path.join(System.tmp_dir!(), "sym-codex-mcp-source-#{System.unique_integer([:positive])}")

    repo_root = Path.expand("..", __DIR__)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo_root, "worktree", "add", "--detach", source_repo, "HEAD"],
               stderr_to_stdout: true
             )

    source_repo
  end

  defp remove_clean_source_repo!(source_repo) do
    repo_root = Path.expand("..", __DIR__)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo_root, "worktree", "remove", "--force", source_repo],
               stderr_to_stdout: true
             )
  end

  defp elixir_runtime_path! do
    repo_root = Path.expand("..", __DIR__)

    {mix_path, 0} =
      System.cmd(
        "bash",
        ["-lc", "mise exec -- which mix"],
        cd: repo_root,
        stderr_to_stdout: true
      )

    Path.dirname(String.trim(mix_path)) <> ":/usr/bin:/bin"
  end
end
