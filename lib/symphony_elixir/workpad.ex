defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Helpers for the persistent Linear workpad comment managed by Symphony.
  """

  @marker "## Symphony Workpad"

  @type review_handoff_status :: {:ready, :no_findings | :unknown} | :blocked

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec find_comment_body(term()) :: String.t() | nil
  def find_comment_body(comments) when is_list(comments) do
    Enum.find_value(comments, fn comment ->
      body = comment_body(comment)

      if comment_matches?(body), do: body
    end)
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

  @spec review_handoff_status(term()) :: review_handoff_status()
  def review_handoff_status(comments) when is_list(comments) do
    comments
    |> find_comment_body()
    |> review_handoff_status()
    |> classify_review_handoff_with_comment_evidence(comments)
  end

  def review_handoff_status(body) when is_binary(body) do
    case section_checklist_status(body, "Review") do
      :closed ->
        {:ready, review_result(body)}
        |> classify_review_handoff_with_comment_evidence([body])

      :open ->
        :blocked

      :missing ->
        :blocked

      :no_checklist ->
        :blocked
    end
  end

  def review_handoff_status(_body), do: :blocked

  defp classify_review_handoff_with_comment_evidence({:ready, :no_findings}, comments)
       when is_list(comments) do
    if review_findings_or_fix_evidence?(comments), do: {:ready, :unknown}, else: {:ready, :no_findings}
  end

  defp classify_review_handoff_with_comment_evidence(status, _comments), do: status

  defp review_result(body) when is_binary(body) do
    {:ok, review_body} = section_body(body, "Review")

    if review_section_no_findings?(review_body), do: :no_findings, else: :unknown
  end

  defp review_section_no_findings?(section_body) when is_binary(section_body) do
    no_findings? =
      Regex.match?(
        ~r/\b(?:keine|no)(?:\s+(?:konkreten|concrete))?\s+findings\b/iu,
        section_body
      ) or
        Regex.match?(~r/\b(?:without|ohne)\s+findings\b/iu, section_body)

    findings_marker? = review_findings_marker?(section_body)

    no_findings? and not findings_marker?
  end

  defp review_findings_or_fix_evidence?(comments) when is_list(comments) do
    Enum.any?(comments, fn comment ->
      comment
      |> comment_body()
      |> review_findings_or_fix_evidence?()
    end)
  end

  defp review_findings_or_fix_evidence?(body) when is_binary(body) do
    review_findings_marker?(body) or
      Regex.match?(~r/\b(?:review-)?subagent-findings?\b/iu, body) or
      Regex.match?(~r/\b(?:p\d+|high|medium|low)-finding\b/iu, body) or
      Regex.match?(~r/\bfinding\s+wurde\b/iu, body) or
      Regex.match?(~r/\bfix-einordnung\b/iu, body) or
      Regex.match?(~r/\breview[-\s]?fix(?:es)?\s+(?:entstanden|erstellt|umgesetzt|angewendet|behandelt)\b/iu, body) or
      Regex.match?(~r/\bfix(?:es)?\s+(?:entstanden|erstellt|umgesetzt|angewendet|behandelt)\b/iu, body) or
      Regex.match?(~r/\bfixrunde\s+\d+\b/iu, body)
  end

  defp review_findings_marker?(body) when is_binary(body) do
    Regex.match?(~r/(?:^|\n)\s*(?:[-*]\s*)?(?:\[[ xX]\]\s*)?(?:\*\*)?findings(?:\*\*)?\s*:/iu, body)
  end

  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(%{"body" => body}) when is_binary(body), do: body
  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_comment), do: ""

  defp section_body(body, section_title) when is_binary(body) and is_binary(section_title) do
    pattern = ~r/(?:^|\n)###\s+#{Regex.escape(section_title)}\s*\n(?<body>.*?)(?=\n###\s+|\z)/s

    case Regex.named_captures(pattern, body) do
      %{"body" => section_body} -> {:ok, section_body}
      _ -> :error
    end
  end
end
