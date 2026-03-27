defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Linear.Issue, Workpad}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    normalized_identifier = String.trim(identifier)

    case Enum.find(issue_entries(), &(&1.identifier == normalized_identifier)) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, {:issue_not_found, normalized_identifier}}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    store_comment(issue_id, body)
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec workpad_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def workpad_exists?(issue_id) do
    {:ok, has_workpad_comment?(issue_id)}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec update_issue_branch_name(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_branch_name(issue_id, branch_name) do
    send_event({:memory_tracker_branch_update, issue_id, branch_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp configured_comments do
    Application.get_env(:symphony_elixir, :memory_tracker_comments, %{})
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp has_workpad_comment?(issue_id) when is_binary(issue_id) do
    configured_comments()
    |> Map.get(issue_id, [])
    |> Enum.any?(&Workpad.comment_matches?/1)
  end

  defp store_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    comments =
      configured_comments()
      |> Map.update(issue_id, [body], &[body | &1])

    Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)
    :ok
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
