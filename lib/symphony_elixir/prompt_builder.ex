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

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "runtime" => runtime_context(issue, session_mode, opts)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
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

  defp runtime_context(issue, session_mode, opts) do
    workflow_mode = workflow_mode(issue, session_mode)
    active_repo_root = active_repo_root(opts)
    source_repo_root = source_repo_root(opts)
    active_repo_skill_root = Path.join(active_repo_root, ".codex/skills")
    global_skill_roots = global_skill_roots()

    %{
      "local_time" => local_timestamp(),
      "timezone" => local_timezone(),
      "session_mode" => Atom.to_string(session_mode),
      "workflow_mode" => Atom.to_string(workflow_mode),
      "automated" => workflow_mode == :automated,
      "interactive" => workflow_mode == :interactive,
      "active_repo_root" => active_repo_root,
      "active_repo_skill_root" => active_repo_skill_root,
      "source_repo_root" => source_repo_root,
      "workflow_file" => workflow_file(opts),
      "workflow_dir" => Path.dirname(workflow_file(opts)),
      "global_skill_roots" => global_skill_roots,
      "global_skill_roots_text" => Enum.join(global_skill_roots, ", "),
      "codex_home" => codex_home_dir() || "",
      "symphony_executable_dir" => symphony_executable_dir() || ""
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

  defp active_repo_root(opts) do
    opts
    |> Keyword.get(:active_repo_root)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_ACTIVE_REPO_ROOT")
        |> present_path()
        |> Kernel.||(source_repo_root(opts))

      path ->
        path
    end
  end

  defp source_repo_root(opts) do
    opts
    |> Keyword.get(:source_repo_root)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_SOURCE_REPO")
        |> present_path()
        |> Kernel.||(Path.dirname(workflow_file(opts)))

      path ->
        path
    end
  end

  defp workflow_file(opts) do
    opts
    |> Keyword.get(:workflow_file)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_WORKFLOW_FILE")
        |> present_path()
        |> Kernel.||(Workflow.workflow_file_path())

      path ->
        path
    end
  end

  defp global_skill_roots do
    [
      codex_home_dir() && Path.join(codex_home_dir(), "skills"),
      symphony_executable_dir()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp codex_home_dir do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" ->
        Path.expand(home)

      _ ->
        case user_home_dir() do
          home when is_binary(home) and home != "" -> Path.join(home, ".codex")
          _ -> nil
        end
    end
  end

  defp symphony_executable_dir do
    case System.find_executable("symphony") do
      nil ->
        Application.get_env(:symphony_elixir, :escript_script_name)
        |> executable_dir_from_script_name()

      path ->
        Path.dirname(path)
    end
  end

  defp executable_dir_from_script_name(script_name) when is_list(script_name) do
    script_name
    |> List.to_string()
    |> executable_dir_from_script_name()
  end

  defp executable_dir_from_script_name(script_name) when is_binary(script_name) do
    if Path.basename(script_name) == "symphony" do
      Path.dirname(script_name)
    end
  end

  defp executable_dir_from_script_name(_script_name), do: nil

  defp user_home_dir do
    Application.get_env(:symphony_elixir, :prompt_builder_user_home, System.user_home())
  end

  defp present_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> Path.expand(trimmed)
    end
  end

  defp present_path(_path), do: nil
end
