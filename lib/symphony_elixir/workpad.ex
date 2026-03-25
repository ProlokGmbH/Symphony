defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Helpers for the persistent Linear workpad comment managed by Symphony.
  """

  @marker "## Codex Workpad"

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec comment_matches?(term()) :: boolean()
  def comment_matches?(body) when is_binary(body) do
    Regex.match?(~r/(^|\n)#{Regex.escape(@marker)}(\n|$)/, body)
  end

  def comment_matches?(_body), do: false
end
