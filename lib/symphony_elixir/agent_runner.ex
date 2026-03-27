defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil
  @prereview_codex_state_name "prereview (ai)"
  @prereview_handoff_state_name "Freigabe"
  @review_codex_state_name "review (ai)"
  @review_handoff_state_name "Test (AI)"
  @test_codex_state_name "test (ai)"
  @test_codex_clean_handoff_state_name "Merge (AI)"
  @freigabe_state_name "Freigabe"
  @test_codex_changed_handoff_state_name @freigabe_state_name
  @merge_codex_state_name "merge (ai)"
  @merge_handoff_state_name "Review"
  @workspace_bootstrap_state_name "in arbeit"

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

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        if workspace_bootstrap_state?(issue.state) do
          bootstrap_issue_workspace(issue, workspace, codex_update_recipient, opts, worker_host)
        else
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                 :ok <- maybe_sync_issue_branch_name(issue, workspace, worker_host) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
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

    with {:ok, initial_workspace_signature} <-
           maybe_capture_initial_workspace_signature(issue, workspace, worker_host),
         {:ok, preflight_result} <-
           maybe_ensure_clean_workspace_before_handoff_phase(
             issue,
             issue_state_fetcher,
             workspace,
             worker_host,
             initial_workspace_signature
           ) do
      turn_context = %{
        workspace: workspace,
        codex_update_recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        worker_host: worker_host,
        initial_workspace_signature: initial_workspace_signature,
        max_turns: max_turns
      }

      continue_run_codex_turns(preflight_result, turn_context, issue)
    end
  end

  defp continue_run_codex_turns(:stop, _turn_context, _issue), do: :ok

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
        initial_workspace_signature: turn_context.initial_workspace_signature,
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
    initial_workspace_signature = turn_context.initial_workspace_signature
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
             worker_host,
             initial_workspace_signature
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
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         workspace,
         worker_host,
         initial_workspace_signature
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        resolve_issue_continuation(
          refreshed_issue,
          issue_state_fetcher,
          workspace,
          worker_host,
          initial_workspace_signature
        )

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(
         issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host,
         _initial_workspace_signature
       ),
       do: {:done, issue}

  defp resolve_issue_continuation(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host,
         initial_workspace_signature
       ) do
    with {:ok, %Issue{} = current_issue, continuation_mode} <-
           maybe_finalize_active_codex_issue(
             issue,
             issue_state_fetcher,
             workspace,
             worker_host,
             initial_workspace_signature
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
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         workspace,
         worker_host,
         initial_workspace_signature
       )
       when is_binary(issue_id) do
    case codex_issue_finalize_mode(issue.state) do
      {:transition, handoff_state_name, error_event, log_label} ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          handoff_state_name,
          error_event,
          log_label,
          :stop
        )

      :test ->
        maybe_finalize_test_codex_issue(
          issue,
          issue_state_fetcher,
          workspace,
          worker_host,
          initial_workspace_signature
        )

      :normal ->
        {:ok, issue, :normal}
    end
  end

  defp maybe_finalize_active_codex_issue(
         %Issue{} = issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host,
         _initial_workspace_signature
       ),
       do: {:ok, issue, :normal}

  defp codex_issue_finalize_mode(state) do
    cond do
      prereview_codex_state?(state) ->
        {:transition, @prereview_handoff_state_name, :prereview_handoff_state_update_failed, "completed prereview issue"}

      review_codex_state?(state) ->
        {:transition, @review_handoff_state_name, :review_handoff_state_update_failed, "completed review issue"}

      test_codex_state?(state) ->
        :test

      merge_codex_state?(state) ->
        {:transition, @merge_handoff_state_name, :merge_handoff_state_update_failed, "completed merge issue"}

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
         workspace,
         worker_host,
         initial_workspace_signature
       ) do
    with {:ok, workspace_changed?} <-
           workspace_changed_since?(workspace, worker_host, initial_workspace_signature) do
      next_state =
        if workspace_changed? do
          @test_codex_changed_handoff_state_name
        else
          @test_codex_clean_handoff_state_name
        end

      transition_issue_state(
        issue,
        issue_state_fetcher,
        next_state,
        :test_handoff_state_update_failed,
        "completed test issue workspace_changed=#{workspace_changed?}",
        :stop
      )
    end
  end

  defp maybe_ensure_clean_workspace_before_handoff_phase(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host,
         initial_workspace_signature
       ) do
    cond do
      test_codex_state?(issue.state) and is_binary(initial_workspace_signature) ->
        maybe_redirect_dirty_workspace_to_review(
          issue,
          issue_state_fetcher,
          initial_workspace_signature
        )

      merge_codex_state?(issue.state) ->
        with {:ok, workspace_signature} <- Workspace.git_status_snapshot(workspace, worker_host) do
          maybe_redirect_dirty_workspace_to_review(issue, issue_state_fetcher, workspace_signature)
        end

      true ->
        {:ok, :continue}
    end
  end

  defp maybe_redirect_dirty_workspace_to_review(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace_signature
       )
       when is_binary(workspace_signature) do
    if workspace_signature == "" do
      {:ok, :continue}
    else
      case transition_issue_state(
             issue,
             issue_state_fetcher,
             @freigabe_state_name,
             :dirty_workspace_handoff_state_update_failed,
             "redirected issue with dirty workspace before #{issue.state}",
             :stop
           ) do
        {:ok, _refreshed_issue, :stop} -> {:ok, :stop}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defp workspace_changed_since?(workspace, worker_host, initial_workspace_signature)
       when is_binary(workspace) and is_binary(initial_workspace_signature) do
    case Workspace.git_status_snapshot(workspace, worker_host) do
      {:ok, current_workspace_signature} ->
        {:ok, current_workspace_signature != initial_workspace_signature}

      {:error, reason} ->
        {:error, {:workspace_status_snapshot_failed, reason}}
    end
  end

  defp workspace_changed_since?(_workspace, _worker_host, nil) do
    {:error, :missing_initial_workspace_signature}
  end

  defp maybe_capture_initial_workspace_signature(%Issue{} = issue, workspace, worker_host)
       when is_binary(workspace) do
    if test_codex_state?(issue.state) do
      Workspace.git_status_snapshot(workspace, worker_host)
    else
      {:ok, nil}
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

  defp bootstrap_issue_workspace(
         %Issue{} = issue,
         workspace,
         codex_update_recipient,
         opts,
         worker_host
       )
       when is_binary(workspace) do
    with :ok <- Workspace.ensure_expected_worktree(workspace, issue, worker_host),
         :ok <- maybe_sync_issue_branch_name(issue, workspace, worker_host),
         {:ok, workpad_exists?} <- workpad_exists_for_issue(issue) do
      if workpad_exists? do
        :ok
      else
        run_workpad_bootstrap_turn(workspace, issue, codex_update_recipient, opts, worker_host)
      end
    end
  end

  defp run_workpad_bootstrap_turn(workspace, issue, codex_update_recipient, opts, worker_host)
       when is_binary(workspace) do
    result =
      with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
        case AppServer.run(
               workspace,
               PromptBuilder.build_prompt(issue, opts),
               issue,
               worker_host: worker_host,
               on_message: codex_message_handler(codex_update_recipient, issue)
             ) do
          {:ok, _turn_session} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    Workspace.run_after_run_hook(workspace, issue, worker_host)
    result
  end

  defp workpad_exists_for_issue(%Issue{id: issue_id}) when is_binary(issue_id) do
    Tracker.workpad_exists?(issue_id)
  end

  defp workpad_exists_for_issue(%Issue{}), do: {:ok, false}

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

  defp workspace_bootstrap_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @workspace_bootstrap_state_name
  end

  defp workspace_bootstrap_state?(_state_name), do: false

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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
