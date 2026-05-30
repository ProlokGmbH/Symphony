defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Helpers for the persistent Linear workpad comment managed by Symphony.
  """

  @marker "## Symphony Workpad"
  @review_evidence_patterns [
    ~r/\b(?:review-)?subagent-findings?\b/iu,
    ~r/\breview[-\s]?finding[-\s]?fix(?:es)?\b/iu,
    ~r/\bkombinierte(?:r|n|s)?\s+nach[-\s]?fix[-\s]?kommentar\b/iu,
    ~r/\bbehandelte[smn]?\s+finding\b/iu,
    ~r/\b(?:p\d+|high|medium|low)-finding\b/iu,
    ~r/\bfinding\s+wurde\b/iu,
    ~r/\bfix-einordnung\b/iu,
    ~r/\breview[-\s]?fix(?:es)?\s+(?:entstanden|erstellt|umgesetzt|angewendet|behandelt)\b/iu,
    ~r/\bfix(?:es)?\s+(?:entstanden|erstellt|umgesetzt|angewendet|behandelt)\b/iu,
    ~r/\bfixrunde\s+\d+\b/iu
  ]

  @type review_handoff_status :: {:ready, :no_findings | :unknown} | :open | :blocked
  @type merge_handoff_status :: :ready | :blocked

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
        :open

      :missing ->
        :blocked

      :no_checklist ->
        :blocked
    end
  end

  def review_handoff_status(_body), do: :blocked

  @spec merge_handoff_status(term()) :: merge_handoff_status()
  def merge_handoff_status(comments) when is_list(comments) do
    comments
    |> find_comment_body()
    |> merge_handoff_status()
  end

  def merge_handoff_status(body) when is_binary(body) do
    if comment_matches?(body) and merge_evidence?(body), do: :ready, else: :blocked
  end

  def merge_handoff_status(_body), do: :blocked

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
    review_findings_marker?(body) or Enum.any?(@review_evidence_patterns, &Regex.match?(&1, body))
  end

  defp review_findings_marker?(body) when is_binary(body) do
    Regex.match?(~r/(?:^|\n)\s*(?:[-*]\s*)?(?:\[[ xX]\]\s*)?(?:\*\*)?findings(?:\*\*)?\s*:/iu, body)
  end

  defp merge_evidence?(body) when is_binary(body) do
    merge_evidence_marker?(body) and merged_pull_request_evidence?(body) and
      merge_commit_evidence?(body)
  end

  defp merge_evidence_marker?(body) when is_binary(body) do
    Regex.match?(~r/\bmerge[-\s]?evidenz\s*:/iu, body) or
      Regex.match?(~r/\bmerge[-\s]?evidence\s*:/iu, body)
  end

  defp merged_pull_request_evidence?(body) when is_binary(body) do
    Regex.match?(
      ~r/\b(?:pr|pull request)\s*#?\d+\b.{0,160}\b(?:gemergt|merged)\b/isu,
      body
    ) or
      Regex.match?(
        ~r/\b(?:gemergt|merged)\b.{0,160}\b(?:pr|pull request)\s*#?\d+\b/isu,
        body
      ) or
      Regex.match?(~r/\bpull\/\d+\b.{0,160}\b(?:gemergt|merged)\b/isu, body) or
      Regex.match?(~r/\b(?:gemergt|merged)\b.{0,160}\bpull\/\d+\b/isu, body)
  end

  defp merge_commit_evidence?(body) when is_binary(body) do
    Regex.match?(~r/\bmerge[-\s]?commit\s*[:#]?\s*`?[0-9a-f]{7,40}`?\b/iu, body)
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
