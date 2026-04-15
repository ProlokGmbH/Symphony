defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Helpers for the persistent Linear workpad comment managed by Symphony.
  """

  @marker "## Codex Workpad"

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec find_comment_body(term()) :: String.t() | nil
  def find_comment_body(comments) when is_list(comments) do
    Enum.find(comments, &comment_matches?/1)
  end

  def find_comment_body(_comments), do: nil

  @spec comment_matches?(term()) :: boolean()
  def comment_matches?(body) when is_binary(body) do
    Regex.match?(~r/(^|\n)#{Regex.escape(@marker)}(\n|$)/, body)
  end

  def comment_matches?(_body), do: false

  @spec section_has_open_checklist_items?(term(), term()) :: boolean()
  def section_has_open_checklist_items?(body, section_title)
      when is_binary(body) and is_binary(section_title) do
    section_checklist_status(body, section_title) == :open
  end

  def section_has_open_checklist_items?(_body, _section_title), do: false

  @spec section_checklist_status(term(), term()) :: :open | :closed | :missing | :no_checklist
  def section_checklist_status(body, section_title)
      when is_binary(body) and is_binary(section_title) do
    case section_body(body, section_title) do
      {:ok, section_body} ->
        cond do
          Regex.match?(~r/^\s*[-*]\s+\[ \]\s+/m, section_body) -> :open
          Regex.match?(~r/^\s*[-*]\s+\[[xX]\]\s+/m, section_body) -> :closed
          true -> :no_checklist
        end

      :error ->
        :missing
    end
  end

  def section_checklist_status(_body, _section_title), do: :missing

  defp section_body(body, section_title) when is_binary(body) and is_binary(section_title) do
    pattern = ~r/(?:^|\n)###\s+#{Regex.escape(section_title)}\s*\n(?<body>.*?)(?=\n###\s+|\z)/s

    case Regex.named_captures(pattern, body) do
      %{"body" => section_body} -> {:ok, section_body}
      _ -> :error
    end
  end
end
