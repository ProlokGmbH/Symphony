defmodule SymphonyElixir.Dialog do
  @moduledoc """
  Helpers for the Linear-backed Dialog-AI workflow.
  """

  alias SymphonyElixir.{PromptBuilder, RuntimePaths, Workflow, Workpad}

  @state_name "Todo (Dialog-AI)"
  @workflow_file_name "WORKFLOW_DIALOG.md"
  @answer_header "### Antwort Symphony"
  @nonblocking_answer_line "[Antwort nicht abgeschlossen]"
  @session_reset_line "[Session zurückgesetzt]"
  @session_pattern ~r/^\[Session\s+([^\]\s]+)\]/m
  @nonblocking_answer_pattern ~r/^\[Antwort\s+nicht\s+abgeschlossen\]/m
  @session_reset_pattern ~r/^\[Session\s+zurückgesetzt\]/m
  @source_pattern ~r/^\[Quelle\s+([^\]\s]+)\]/m
  @first_turn_source_key "first-turn"

  @type comment :: %{optional(atom() | String.t()) => term()}
  @type request :: %{
          prompt: String.t(),
          session_id: String.t() | nil,
          include_session?: boolean(),
          source_comment_id: String.t() | nil,
          source_comment_timestamp: DateTime.t() | nil,
          source_comment_body: String.t() | nil
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
    open_comment = latest_open_request_comment(relevant_comments)

    cond do
      answer_exists? and not is_nil(open_comment) ->
        follow_up_request(issue, active_repo_root, relevant_comments, open_comment)

      not is_nil(open_comment) ->
        with {:ok, prompt} <- first_turn_prompt(issue, active_repo_root, comment_body(open_comment)) do
          {:ok, request(prompt, nil, true, open_comment)}
        end

      answer_exists? or source_scoped_nonblocking_answer_exists?(relevant_comments) ->
        {:ok, :noop}

      true ->
        with {:ok, prompt} <- first_turn_prompt(issue, active_repo_root) do
          {:ok, request(prompt, nil, true, nil)}
        end
    end
  end

  @spec request_current?(request(), [comment()]) :: boolean()
  def request_current?(%{} = request, comments) when is_list(comments) do
    relevant_comments = relevant_comments(comments)

    if request_source_covered?(request, relevant_comments) do
      false
    else
      case {request_source_comment?(request), relevant_comments |> actionable_comments() |> List.last()} do
        {false, nil} -> true
        {false, _comment} -> false
        {true, nil} -> false
        {true, comment} -> not answer_comment?(comment) and source_comment_matches?(request, comment)
      end
    end
  end

  @spec answer_comment?(term()) :: boolean()
  def answer_comment?(comment) do
    body = comment_body(comment)

    body
    |> String.trim_leading()
    |> String.starts_with?(@answer_header) and not nonblocking_answer_body?(body)
  end

  @spec nonblocking_answer_comment?(term()) :: boolean()
  def nonblocking_answer_comment?(comment), do: nonblocking_answer_body?(comment_body(comment))

  @spec session_id_from_comments([comment()]) :: String.t() | nil
  def session_id_from_comments(comments) when is_list(comments) do
    comments
    |> order_comments()
    |> Enum.reverse()
    |> Enum.find_value(fn comment ->
      body = comment_body(comment)

      cond do
        Regex.match?(@session_reset_pattern, body) ->
          :session_reset

        nonblocking_answer_body?(body) ->
          nil

        match = Regex.run(@session_pattern, body) ->
          [_, session_id] = match
          session_id

        true ->
          nil
      end
    end)
    |> case do
      :session_reset -> nil
      session_id -> session_id
    end
  end

  @spec format_answer_comment(String.t(), String.t() | nil, boolean()) :: String.t()
  def format_answer_comment(answer, session_id, include_session?)
      when is_binary(answer) and is_boolean(include_session?) do
    body = strip_answer_header(answer)
    session_line = session_line(session_id, include_session?)

    format_answer_parts([@answer_header, session_line, body])
  end

  @spec format_nonblocking_answer_comment(String.t(), String.t() | nil, boolean()) :: String.t()
  def format_nonblocking_answer_comment(answer, session_id, include_session?)
      when is_binary(answer) and is_boolean(include_session?) do
    format_nonblocking_answer_comment(answer, session_id, include_session?, nil)
  end

  @spec format_nonblocking_answer_comment(String.t(), String.t() | nil, boolean(), String.t() | nil) :: String.t()
  def format_nonblocking_answer_comment(answer, session_id, include_session?, source_key)
      when is_binary(answer) and is_boolean(include_session?) do
    body = strip_answer_header(answer)
    session_line = session_line(session_id, include_session?)

    format_answer_parts([@answer_header, @nonblocking_answer_line, source_line(source_key), session_line, body])
  end

  @spec format_session_reset_answer_comment(String.t()) :: String.t()
  def format_session_reset_answer_comment(answer) when is_binary(answer) do
    body = strip_answer_header(answer)
    format_answer_parts([@answer_header, @session_reset_line, body])
  end

  @spec format_nonblocking_session_reset_answer_comment(String.t()) :: String.t()
  def format_nonblocking_session_reset_answer_comment(answer) when is_binary(answer) do
    format_nonblocking_session_reset_answer_comment(answer, nil)
  end

  @spec format_nonblocking_session_reset_answer_comment(String.t(), String.t() | nil) :: String.t()
  def format_nonblocking_session_reset_answer_comment(answer, source_key) when is_binary(answer) do
    body = strip_answer_header(answer)
    format_answer_parts([@answer_header, @nonblocking_answer_line, source_line(source_key), @session_reset_line, body])
  end

  @spec request_source_key(request()) :: String.t()
  def request_source_key(%{} = request) do
    cond do
      is_binary(Map.get(request, :source_comment_id)) and Map.get(request, :source_comment_id) != "" ->
        "id:#{Map.get(request, :source_comment_id)}"

      match?(%DateTime{}, Map.get(request, :source_comment_timestamp)) and is_binary(Map.get(request, :source_comment_body)) ->
        source_hash([DateTime.to_iso8601(Map.get(request, :source_comment_timestamp)), Map.get(request, :source_comment_body)])

      is_binary(Map.get(request, :source_comment_body)) ->
        source_hash([Map.get(request, :source_comment_body)])

      true ->
        @first_turn_source_key
    end
  end

  defp format_answer_parts(parts) when is_list(parts) do
    parts
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

  defp actionable_comments(comments) when is_list(comments) do
    Enum.reject(comments, &nonblocking_answer_comment?/1)
  end

  defp follow_up_request(issue, active_repo_root, relevant_comments, open_comment) do
    case session_id_from_comments(relevant_comments) do
      nil ->
        with {:ok, prompt} <- first_turn_prompt(issue, active_repo_root, comment_body(open_comment)) do
          {:ok, request(prompt, nil, true, open_comment)}
        end

      session_id ->
        {:ok, request(comment_body(open_comment), session_id, false, open_comment)}
    end
  end

  defp latest_open_request_comment(relevant_comments) when is_list(relevant_comments) do
    comments = comments_after_last_answer(relevant_comments)
    nonblocking_answer_comments = Enum.filter(comments, &nonblocking_answer_comment?/1)

    comments
    |> Enum.reject(
      &(answer_comment?(&1) or nonblocking_answer_comment?(&1) or
          source_comment_covered?(&1, nonblocking_answer_comments))
    )
    |> List.last()
  end

  defp comments_after_last_answer(comments) when is_list(comments) do
    last_answer_index =
      comments
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {comment, index}, acc ->
        if answer_comment?(comment), do: index, else: acc
      end)

    case last_answer_index do
      nil -> comments
      index -> Enum.drop(comments, index + 1)
    end
  end

  defp source_scoped_nonblocking_answer_exists?(comments) when is_list(comments) do
    comments
    |> nonblocking_source_keys()
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp request_source_covered?(request, comments) when is_map(request) and is_list(comments) do
    request_source_keys = request_source_keys(request)

    comments
    |> Enum.filter(&nonblocking_answer_comment?/1)
    |> Enum.any?(fn answer_comment ->
      case nonblocking_source_key(answer_comment) do
        nil ->
          false

        source_key ->
          source_key in request_source_keys and not request_activity_after?(request, answer_comment)
      end
    end)
  end

  defp nonblocking_source_keys(comments) when is_list(comments) do
    comments
    |> Enum.filter(&nonblocking_answer_comment?/1)
    |> Enum.map(&nonblocking_source_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp nonblocking_source_key(comment) do
    case Regex.run(@source_pattern, comment_body(comment)) do
      [_, source_key] -> source_key
      _ -> nil
    end
  end

  defp source_comment_covered?(comment, nonblocking_answer_comments) do
    comment_source_keys = comment_source_keys(comment)

    Enum.any?(nonblocking_answer_comments, fn answer_comment ->
      case nonblocking_source_key(answer_comment) do
        nil ->
          false

        source_key ->
          source_key in comment_source_keys and
            not comment_activity_after?(comment, answer_comment)
      end
    end)
  end

  defp comment_source_keys(comment) do
    id = comment_id(comment)
    timestamp = comment_timestamp(comment)
    body = comment_body(comment)

    timestamp_source_key =
      if match?(%DateTime{}, timestamp) do
        source_hash([DateTime.to_iso8601(timestamp), body])
      end

    []
    |> maybe_prepend_source_key(if(is_binary(id), do: "id:#{id}"))
    |> maybe_prepend_source_key(timestamp_source_key)
    |> maybe_prepend_source_key(if(body != "", do: source_hash([body])))
  end

  defp maybe_prepend_source_key(keys, source_key) when is_binary(source_key), do: [source_key | keys]
  defp maybe_prepend_source_key(keys, _source_key), do: keys

  defp request_source_keys(request) when is_map(request) do
    id = Map.get(request, :source_comment_id)
    timestamp = Map.get(request, :source_comment_timestamp)
    body = Map.get(request, :source_comment_body)

    []
    |> maybe_prepend_source_key(if(is_binary(id) and id != "", do: "id:#{id}"))
    |> maybe_prepend_source_key(timestamp_body_source_key(timestamp, body))
    |> maybe_prepend_source_key(if(is_binary(body), do: source_hash([body])))
    |> case do
      [] -> [@first_turn_source_key]
      keys -> keys
    end
  end

  defp timestamp_body_source_key(%DateTime{} = timestamp, body) when is_binary(body) do
    source_hash([DateTime.to_iso8601(timestamp), body])
  end

  defp timestamp_body_source_key(_timestamp, _body), do: nil

  defp request_activity_after?(request, reference_comment) when is_map(request) do
    case {Map.get(request, :source_comment_timestamp), comment_timestamp(reference_comment)} do
      {%DateTime{} = request_timestamp, %DateTime{} = reference_timestamp} ->
        DateTime.compare(request_timestamp, reference_timestamp) == :gt

      _ ->
        false
    end
  end

  defp comment_activity_after?(comment, reference_comment) do
    case {comment_timestamp(comment), comment_timestamp(reference_comment)} do
      {%DateTime{} = comment_timestamp, %DateTime{} = reference_timestamp} ->
        DateTime.compare(comment_timestamp, reference_timestamp) == :gt

      _ ->
        false
    end
  end

  defp nonblocking_answer_body?(body) when is_binary(body) do
    body = String.trim_leading(body)
    String.starts_with?(body, @answer_header) and Regex.match?(@nonblocking_answer_pattern, body)
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

  defp first_turn_prompt(issue, active_repo_root, request_body)
       when is_map(issue) and is_binary(active_repo_root) and is_binary(request_body) do
    with {:ok, prompt} <- first_turn_prompt(issue, active_repo_root) do
      {:ok, append_linear_comment_request(prompt, request_body)}
    end
  end

  defp append_linear_comment_request(prompt, request_body)
       when is_binary(prompt) and is_binary(request_body) do
    prompt <>
      "\n\n## Aktuelle Benutzeranfrage aus Linear-Kommentar\n\n" <> String.trim(request_body)
  end

  defp request(prompt, session_id, include_session?, source_comment)
       when is_binary(prompt) and is_boolean(include_session?) do
    %{
      prompt: prompt,
      session_id: session_id,
      include_session?: include_session?,
      source_comment_id: comment_id(source_comment),
      source_comment_timestamp: comment_timestamp(source_comment),
      source_comment_body: source_comment_body(source_comment)
    }
  end

  defp request_source_comment?(request) when is_map(request) do
    Map.get(request, :source_comment_id) != nil or Map.get(request, :source_comment_timestamp) != nil or
      Map.get(request, :source_comment_body) != nil
  end

  defp source_comment_matches?(request, comment) when is_map(request) do
    source_comment_matches_by_id?(request, comment_id(comment), comment)
  end

  defp source_comment_matches_by_id?(%{source_comment_id: request_id} = request, comment_id, comment)
       when is_binary(request_id) and is_binary(comment_id) do
    request_id == comment_id and source_comment_content_matches?(request, comment)
  end

  defp source_comment_matches_by_id?(request, _comment_id, comment), do: source_comment_content_matches?(request, comment)

  defp source_comment_content_matches?(request, comment) do
    Map.get(request, :source_comment_body) == comment_body(comment) and
      source_comment_timestamp_matches?(Map.get(request, :source_comment_timestamp), comment_timestamp(comment))
  end

  defp source_comment_timestamp_matches?(%DateTime{} = request_timestamp, %DateTime{} = comment_timestamp) do
    DateTime.compare(request_timestamp, comment_timestamp) == :eq
  end

  defp source_comment_timestamp_matches?(_request_timestamp, _comment_timestamp), do: true

  defp comment_id(comment) when is_map(comment) do
    case map_get(comment, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp comment_id(_comment), do: nil

  defp source_comment_body(nil), do: nil
  defp source_comment_body(comment), do: comment_body(comment)

  defp comment_body(comment) when is_map(comment) do
    case Map.get(comment, :body) || Map.get(comment, "body") do
      body when is_binary(body) -> body
      _ -> ""
    end
  end

  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_comment), do: ""

  defp comment_timestamp(comment) when is_map(comment) do
    [:updated_at, :created_at, "updated_at", "created_at", "updatedAt", "createdAt"]
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

  defp source_line(source_key) when is_binary(source_key) and source_key != "", do: "[Quelle #{source_key}]"
  defp source_line(_source_key), do: ""

  defp source_hash(parts) when is_list(parts) do
    value = Enum.join(parts, <<0>>)

    "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  end

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
