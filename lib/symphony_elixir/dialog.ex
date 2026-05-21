defmodule SymphonyElixir.Dialog do
  @moduledoc """
  Helpers for the Linear-backed Dialog-AI workflow.
  """

  alias SymphonyElixir.{PromptBuilder, RuntimePaths, Workflow, Workpad}

  @state_name "Todo (Dialog-AI)"
  @workflow_file_name "WORKFLOW_DIALOG.md"
  @answer_header "### Antwort Symphony"
  @session_pattern ~r/^\[Session\s+([^\]\s]+)\]/m

  @type comment :: %{optional(atom() | String.t()) => term()}
  @type request :: %{
          prompt: String.t(),
          session_id: String.t() | nil,
          include_session?: boolean()
        }

  @spec state_name() :: String.t()
  def state_name, do: @state_name

  @spec state?(term()) :: boolean()
  def state?(state_name) when is_binary(state_name) do
    normalize(state_name) == normalize(@state_name)
  end

  def state?(_state_name), do: false

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :dialog_workflow_file_path) ||
      default_workflow_file_path()
  end

  @spec default_workflow_file_path() :: Path.t()
  def default_workflow_file_path do
    Workflow.workflow_file_path()
    |> Path.dirname()
    |> Path.join(@workflow_file_name)
  end

  @spec prompt_template() :: {:ok, String.t()} | {:error, term()}
  def prompt_template do
    with {:ok, %{prompt_template: prompt_template}} <- Workflow.load(workflow_file_path()) do
      {:ok, prompt_template}
    end
  end

  @spec first_turn_prompt(map(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def first_turn_prompt(issue, active_repo_root) when is_map(issue) and is_binary(active_repo_root) do
    with {:ok, prompt_template} <- prompt_template() do
      {:ok,
       PromptBuilder.build_prompt(
         issue,
         prompt_template: prompt_template,
         session_mode: :orchestrated,
         active_repo_root: active_repo_root,
         source_repo_root: RuntimePaths.project_root(),
         workflow_file: workflow_file_path()
       )}
    end
  end

  @spec next_request(map(), [comment()], Path.t()) :: {:ok, request() | :noop} | {:error, term()}
  def next_request(issue, comments, active_repo_root)
      when is_map(issue) and is_list(comments) and is_binary(active_repo_root) do
    relevant_comments = relevant_comments(comments)
    answer_exists? = Enum.any?(relevant_comments, &answer_comment?/1)
    last_comment = List.last(relevant_comments)

    cond do
      answer_exists? and answer_comment?(last_comment) ->
        {:ok, :noop}

      not answer_exists? ->
        with {:ok, prompt} <- first_turn_prompt(issue, active_repo_root) do
          {:ok, %{prompt: prompt, session_id: nil, include_session?: true}}
        end

      true ->
        {:ok,
         %{
           prompt: comment_body(last_comment),
           session_id: session_id_from_comments(relevant_comments),
           include_session?: false
         }}
    end
  end

  @spec answer_comment?(term()) :: boolean()
  def answer_comment?(comment) do
    comment
    |> comment_body()
    |> String.trim_leading()
    |> String.starts_with?(@answer_header)
  end

  @spec session_id_from_comments([comment()]) :: String.t() | nil
  def session_id_from_comments(comments) when is_list(comments) do
    comments
    |> order_comments()
    |> Enum.reverse()
    |> Enum.find_value(fn comment ->
      case Regex.run(@session_pattern, comment_body(comment)) do
        [_, session_id] -> session_id
        _ -> nil
      end
    end)
  end

  @spec format_answer_comment(String.t(), String.t() | nil, boolean()) :: String.t()
  def format_answer_comment(answer, session_id, include_session?)
      when is_binary(answer) and is_boolean(include_session?) do
    body = strip_answer_header(answer)
    session_line = session_line(session_id, include_session?)

    [@answer_header, session_line, body]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @spec final_answer_from_messages([map()]) :: String.t() | nil
  def final_answer_from_messages(messages) when is_list(messages) do
    {final_answers, fallback_answers} =
      Enum.reduce(messages, {[], []}, fn message, {final_acc, fallback_acc} ->
        case agent_message_from_update(message) do
          %{text: text, phase: "final_answer"} when is_binary(text) ->
            {[text | final_acc], fallback_acc}

          %{text: text} when is_binary(text) ->
            {final_acc, [text | fallback_acc]}

          _ ->
            {final_acc, fallback_acc}
        end
      end)

    (List.first(final_answers) || List.first(fallback_answers))
    |> normalize_answer_text()
  end

  defp relevant_comments(comments) do
    comments
    |> order_comments()
    |> Enum.reject(fn comment ->
      body = comment_body(comment)
      String.trim(body) == "" or Workpad.comment_matches?(body)
    end)
  end

  defp order_comments(comments) do
    tagged_comments = Enum.map(comments, &{comment_timestamp(&1), &1})

    if Enum.all?(tagged_comments, fn {timestamp, _comment} -> match?(%DateTime{}, timestamp) end) do
      tagged_comments
      |> Enum.sort_by(fn {timestamp, _comment} -> DateTime.to_unix(timestamp, :microsecond) end)
      |> Enum.map(fn {_timestamp, comment} -> comment end)
    else
      comments
    end
  end

  defp comment_body(comment) when is_map(comment) do
    case Map.get(comment, :body) || Map.get(comment, "body") do
      body when is_binary(body) -> body
      _ -> ""
    end
  end

  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_comment), do: ""

  defp comment_timestamp(comment) when is_map(comment) do
    [:created_at, :updated_at, "created_at", "updated_at", "createdAt", "updatedAt"]
    |> Enum.find_value(fn key -> parse_timestamp(Map.get(comment, key)) end)
  end

  defp comment_timestamp(_comment), do: nil

  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp

  defp parse_timestamp(raw_timestamp) when is_binary(raw_timestamp) do
    case DateTime.from_iso8601(raw_timestamp) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp parse_timestamp(_raw_timestamp), do: nil

  defp strip_answer_header(answer) when is_binary(answer) do
    answer
    |> String.trim()
    |> String.replace(~r/\A###\s+Antwort\s+Symphony\s*/u, "")
    |> String.trim()
  end

  defp session_line(session_id, true) when is_binary(session_id) do
    trimmed_session_id = String.trim(session_id)

    if trimmed_session_id == "" do
      ""
    else
      "[Session #{trimmed_session_id}]"
    end
  end

  defp session_line(_session_id, _include_session?), do: ""

  defp agent_message_from_update(message) when is_map(message) do
    message
    |> map_get(:payload)
    |> Kernel.||(message)
    |> agent_message_from_payload()
  end

  defp agent_message_from_update(payload), do: agent_message_from_payload(payload)

  defp agent_message_from_payload(payload) when is_map(payload) do
    params = map_get(payload, :params)
    item = if is_map(params), do: map_get(params, :item), else: nil

    if map_get(payload, :method) == "item/completed" and is_map(item) and
         map_get(item, :type) == "agentMessage" and is_binary(map_get(item, :text)) do
      %{text: map_get(item, :text), phase: map_get(item, :phase)}
    end
  end

  defp agent_message_from_payload(_payload), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_answer_text(nil), do: nil

  defp normalize_answer_text(answer) when is_binary(answer) do
    case String.trim(answer) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
