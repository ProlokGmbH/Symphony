defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workflow, Workspace}

  @type worker_host :: String.t() | nil
  @prereview_codex_state_name "prereview (ai)"
  @review_codex_state_name "review (ai)"
  @test_codex_state_name "test (ai)"
  @implementation_handoff_state_name "Freigabe Implementierung"
  @review_handoff_state_name "Freigabe Review"
  @post_review_clean_state_name "Test (AI)"
  @test_handoff_state_name "Merge (AI)"
  @merge_codex_state_name "merge (ai)"
  @merge_handoff_state_name "Review"
  @ignored_manual_state_names [
    "todo",
    "in arbeit",
    "freigabe",
    "freigabe planung",
    "freigabe implementierung",
    "freigabe review",
    "freigabe final"
  ]

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case maybe_skip_manual_issue_state(issue, issue_state_fetcher) do
      {:ok, %Issue{} = transitioned_issue, :continue} ->
        run_on_worker_host(transitioned_issue, codex_update_recipient, opts, worker_host)

      :manual_noop ->
        Logger.info("Skipping manual-only issue state for #{issue_context(issue)} state=#{inspect(issue.state)}")
        :ok

      :proceed ->
        case Workspace.create_for_issue(issue, worker_host) do
          {:ok, workspace} ->
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

            try do
              with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                   :ok <- maybe_sync_issue_branch_name(issue, workspace, worker_host) do
                run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
              end
            after
              Workspace.run_after_run_hook(workspace, issue, worker_host)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_skip_manual_issue_state(%Issue{} = issue, issue_state_fetcher) do
    cond do
      not ignored_manual_state?(issue.state) ->
        :proceed

      not skip_current_manual_state?(issue) ->
        :manual_noop

      true ->
        case Workflow.resolve_next_status(issue.state, Issue.label_names(issue)) do
          next_state when is_binary(next_state) ->
            transition_issue_state(
              issue,
              issue_state_fetcher,
              next_state,
              :manual_skip_state_update_failed,
              "skipped manual issue state",
              :continue
            )

          _ ->
            :manual_noop
        end
    end
  end

  defp skip_current_manual_state?(%Issue{} = issue) do
    current_state = normalize_issue_state(issue.state)

    Issue.label_names(issue)
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.any?(fn label ->
      label == ~s(skip "#{current_state}") or label == "skip #{current_state}"
    end)
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    turn_context = %{
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      worker_host: worker_host,
      max_turns: max_turns
    }

    continue_run_codex_turns(:continue, turn_context, issue)
  end

  defp continue_run_codex_turns(:continue, turn_context, issue) when is_map(turn_context) do
    workspace = turn_context.workspace
    worker_host = turn_context.worker_host

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      run_context = %{
        app_session: session,
        workspace: workspace,
        codex_update_recipient: turn_context.codex_update_recipient,
        opts: turn_context.opts,
        issue_state_fetcher: turn_context.issue_state_fetcher,
        worker_host: worker_host,
        max_turns: turn_context.max_turns
      }

      try do
        do_run_codex_turns(run_context, issue, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(turn_context, issue, turn_number) when is_map(turn_context) do
    app_session = turn_context.app_session
    workspace = turn_context.workspace
    codex_update_recipient = turn_context.codex_update_recipient
    opts = turn_context.opts
    issue_state_fetcher = turn_context.issue_state_fetcher
    worker_host = turn_context.worker_host
    max_turns = turn_context.max_turns
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(
             issue,
             issue_state_fetcher,
             workspace,
             worker_host
           ) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(turn_context, refreshed_issue, turn_number + 1)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    PromptBuilder.build_prompt(issue, Keyword.put_new(opts, :session_mode, :orchestrated))
  end

  defp build_turn_prompt(%Issue{} = issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - The current tracker state is "#{issue.state}".
    - Follow the workflow instructions for the current tracker state before deciding what to do next.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(
         %Issue{id: issue_id} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        resolve_issue_continuation(
          started_issue,
          refreshed_issue,
          issue_state_fetcher,
          workspace,
          worker_host
        )

      {:ok, []} ->
        {:done, started_issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(
         started_issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host
       ),
       do: {:done, started_issue}

  defp resolve_issue_continuation(
         %Issue{} = started_issue,
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    with {:ok, %Issue{} = current_issue, continuation_mode} <-
           maybe_finalize_active_codex_issue(
             started_issue,
             issue,
             issue_state_fetcher,
             workspace,
             worker_host
           ) do
      continuation_status(current_issue, continuation_mode)
    end
  end

  defp continuation_status(%Issue{} = issue, :stop) do
    {:done, issue}
  end

  defp continuation_status(%Issue{} = issue, _continuation_mode) do
    if active_issue_state?(issue.state) do
      {:continue, issue}
    else
      {:done, issue}
    end
  end

  defp maybe_finalize_active_codex_issue(
         %Issue{} = started_issue,
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    if state_changed_during_turn?(started_issue, issue) do
      {:ok, issue, :normal}
    else
      case codex_issue_finalize_mode(started_issue.state) do
        {:transition, error_event, log_label} ->
          transition_issue_state(
            issue,
            issue_state_fetcher,
            resolve_next_handoff_state(issue),
            error_event,
            log_label,
            :stop
          )

        :review ->
          maybe_finalize_review_codex_issue(
            issue,
            issue_state_fetcher,
            workspace,
            worker_host
          )

        :test ->
          maybe_finalize_test_codex_issue(
            issue,
            issue_state_fetcher,
            workspace,
            worker_host
          )

        :normal ->
          {:ok, issue, :normal}
      end
    end
  end

  defp maybe_finalize_active_codex_issue(
         _started_issue,
         %Issue{} = issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host
       ),
       do: {:ok, issue, :normal}

  defp codex_issue_finalize_mode(state) do
    cond do
      prereview_codex_state?(state) ->
        {:transition, :prereview_handoff_state_update_failed, "completed prereview issue"}

      review_codex_state?(state) ->
        :review

      test_codex_state?(state) ->
        :test

      merge_codex_state?(state) ->
        {:transition, :merge_handoff_state_update_failed, "completed merge issue"}

      true ->
        :normal
    end
  end

  defp refetch_issue(%Issue{id: issue_id} = issue, issue_state_fetcher, fallback_state)
       when is_binary(issue_id) and is_binary(fallback_state) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        {:ok, refreshed_issue}

      {:ok, []} ->
        {:ok, %{issue | state: fallback_state}}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp maybe_finalize_test_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         _workspace,
         _worker_host
       ) do
    transition_issue_state(
      issue,
      issue_state_fetcher,
      resolve_next_handoff_state(issue),
      :test_handoff_state_update_failed,
      "completed test issue",
      :stop
    )
  end

  defp maybe_finalize_review_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    transition_issue_state(
      issue,
      issue_state_fetcher,
      resolve_review_handoff_state(issue, workspace, worker_host),
      :review_handoff_state_update_failed,
      "completed review issue",
      :stop
    )
  end

  defp transition_issue_state(
         %Issue{} = issue,
         issue_state_fetcher,
         next_state,
         error_tag,
         reason_label,
         continuation_mode
       )
       when is_binary(next_state) and is_atom(error_tag) do
    case Tracker.update_issue_state(issue.id, next_state) do
      :ok ->
        Logger.info("Auto-transitioned #{reason_label}: #{issue_context(issue)} next_state=#{next_state}")

        with {:ok, %Issue{} = refreshed_issue} <- refetch_issue(issue, issue_state_fetcher, next_state) do
          {:ok, refreshed_issue, continuation_mode}
        end

      {:error, reason} ->
        Logger.warning("Failed auto-transition for #{reason_label}: #{issue_context(issue)} next_state=#{next_state} reason=#{inspect(reason)}")

        {:error, {error_tag, next_state, reason}}
    end
  end

  defp maybe_sync_issue_branch_name(%Issue{id: issue_id}, _workspace, _worker_host)
       when not is_binary(issue_id),
       do: :ok

  defp maybe_sync_issue_branch_name(%Issue{} = issue, workspace, worker_host)
       when is_binary(workspace) do
    with {:ok, branch_name} <- Workspace.current_branch(workspace, worker_host),
         :ok <- Tracker.update_issue_branch_name(issue.id, branch_name) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to sync Linear branch name for #{issue_context(issue)}: #{inspect(reason)}")

        :ok
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp prereview_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @prereview_codex_state_name
  end

  defp prereview_codex_state?(_state_name), do: false

  defp review_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @review_codex_state_name
  end

  defp review_codex_state?(_state_name), do: false

  defp test_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @test_codex_state_name
  end

  defp test_codex_state?(_state_name), do: false

  defp merge_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @merge_codex_state_name
  end

  defp merge_codex_state?(_state_name), do: false

  defp ignored_manual_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(@ignored_manual_state_names, &(&1 == normalized_state))
  end

  defp ignored_manual_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp state_changed_during_turn?(%Issue{state: started_state}, %Issue{state: current_state})
       when is_binary(started_state) and is_binary(current_state) do
    normalize_issue_state(started_state) != normalize_issue_state(current_state)
  end

  defp state_changed_during_turn?(_started_issue, _current_issue), do: false

  defp resolve_next_handoff_state(%Issue{} = issue) do
    Workflow.resolve_next_status(issue.state, Issue.label_names(issue)) ||
      default_next_handoff_state(issue.state)
  end

  defp resolve_review_handoff_state(%Issue{} = issue, workspace, worker_host)
       when is_binary(workspace) do
    case Workspace.git_status_snapshot(workspace, worker_host) do
      {:ok, status_snapshot} ->
        if String.trim(status_snapshot) == "" do
          Workflow.resolve_target_status(
            @review_handoff_state_name,
            [~s(skip "freigabe review") | Issue.label_names(issue)]
          ) || @post_review_clean_state_name
        else
          resolve_next_handoff_state(issue)
        end

      {:error, reason} ->
        Logger.warning("Failed to inspect workspace state after review completion; falling back to standard review handoff: #{issue_context(issue)} reason=#{inspect(reason)}")

        resolve_next_handoff_state(issue)
    end
  end

  defp default_next_handoff_state(state_name) when is_binary(state_name) do
    cond do
      prereview_codex_state?(state_name) -> @implementation_handoff_state_name
      review_codex_state?(state_name) -> @review_handoff_state_name
      test_codex_state?(state_name) -> @test_handoff_state_name
      merge_codex_state?(state_name) -> @merge_handoff_state_name
      true -> state_name
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
