defmodule SymCodexMcpScriptTest do
  use ExUnit.Case

  @script_path Path.expand("../sym-codex-mcp", __DIR__)
  @source_repo Path.expand("..", __DIR__)
  @workflow_file Path.join(@source_repo, "WORKFLOW.md")

  test "sym-codex-mcp serves initialize and tools/list over stdio" do
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

    on_exit(fn -> File.rm(input_file) end)

    {output, 0} =
      System.cmd(
        "bash",
        ["-lc", "cat \"$INPUT_FILE\" | \"$SCRIPT_PATH\""],
        env: [
          {"INPUT_FILE", input_file},
          {"SCRIPT_PATH", @script_path},
          {"SYMPHONY_SOURCE_REPO", @source_repo},
          {"SYMPHONY_WORKFLOW_FILE", @workflow_file}
        ],
        stderr_to_stdout: true
      )

    [initialize_line, tools_list_line] = String.split(output, "\n", trim: true)
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
end
