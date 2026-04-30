defmodule SymphonyElixir.AutocommitMessage do
  @moduledoc """
  Builds issue-scoped commit messages for automated workspace snapshots.
  """

  alias SymphonyElixir.Linear.Issue

  @fallback_identifier "Unbekanntes Issue"

  @spec build(Issue.t() | map() | String.t() | nil, String.t()) :: String.t()
  def build(issue_or_identifier, workflow_state) when is_binary(workflow_state) do
    identifier = issue_identifier(issue_or_identifier)
    state = String.trim(workflow_state)

    [
      "#{identifier} #{state} Autocommit",
      "",
      "Dieser automatische Commit wird im Schritt #{state} erstellt und sichert den bis dahin offenen Arbeitsstand für #{identifier}. Er ist kein Nachweis, dass #{state} bereits abgeschlossen ist."
    ]
    |> Enum.join("\n")
  end

  defp issue_identifier(%Issue{identifier: identifier}), do: issue_identifier(identifier)
  defp issue_identifier(%{identifier: identifier}), do: issue_identifier(identifier)

  defp issue_identifier(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> @fallback_identifier
      identifier -> identifier
    end
  end

  defp issue_identifier(_issue_or_identifier), do: @fallback_identifier
end
