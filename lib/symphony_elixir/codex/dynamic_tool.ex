defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.LinearGraphqlTool

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      "linear_graphql" ->
        LinearGraphqlTool.execute(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [LinearGraphqlTool.tool_spec()]
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "output" => Jason.encode!(payload, pretty: true),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => Jason.encode!(payload, pretty: true)
        }
      ]
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
