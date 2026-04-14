defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Tracker, Workflow}

  @type session_mode :: :manual | :orchestrated
  @type workflow_mode :: :automated | :interactive

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    session_mode = session_mode(opts)

    template =
      prompt_template_from_opts(opts)
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "runtime" => runtime_context(issue, session_mode)
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    append_recovered_turn_context(rendered_prompt, Keyword.get(opts, :recovered_turn_context))
  end

  @spec build_prompt_for_issue_identifier(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_prompt_for_issue_identifier(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, issue} <- Tracker.fetch_issue_by_identifier(identifier) do
      {:ok, build_prompt(issue, opts)}
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp prompt_template_from_opts(opts) do
    case Keyword.get(opts, :prompt_template) do
      prompt when is_binary(prompt) ->
        default_prompt(prompt)

      _ ->
        Workflow.current()
        |> prompt_template!()
    end
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp runtime_context(issue, session_mode) do
    workflow_mode = workflow_mode(issue, session_mode)

    %{
      "local_time" => local_timestamp(),
      "timezone" => local_timezone(),
      "session_mode" => Atom.to_string(session_mode),
      "workflow_mode" => Atom.to_string(workflow_mode),
      "automated" => workflow_mode == :automated,
      "interactive" => workflow_mode == :interactive
    }
  end

  defp workflow_mode(%{state: state}, :orchestrated) when is_binary(state) do
    if automated_issue_state?(state) do
      :automated
    else
      :interactive
    end
  end

  defp workflow_mode(%{state: state}, _session_mode) when is_binary(state) do
    if automated_issue_state?(state) do
      :automated
    else
      :interactive
    end
  end

  defp workflow_mode(_issue, _session_mode), do: :interactive

  defp automated_issue_state?(state) when is_binary(state) do
    String.ends_with?(String.trim(state), "(AI)")
  end

  defp session_mode(opts) do
    case Keyword.get(opts, :session_mode, :orchestrated) do
      :manual -> :manual
      :orchestrated -> :orchestrated
      _ -> :orchestrated
    end
  end

  defp local_timestamp do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  defp local_timezone do
    case System.get_env("TZ") do
      timezone when is_binary(timezone) ->
        case String.trim(timezone) do
          "" -> "system-local"
          trimmed -> trimmed
        end

      _ ->
        "system-local"
    end
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp append_recovered_turn_context(prompt, context) when is_binary(prompt) and is_binary(context) do
    trimmed_context = String.trim(context)

    if trimmed_context == "" do
      prompt
    else
      prompt <>
        "\n\n" <> Workflow.prompt_snippet("recovered_turn_context", %{context: trimmed_context})
    end
  end

  defp append_recovered_turn_context(prompt, _context), do: prompt
end
