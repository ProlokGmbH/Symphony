defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    AutocommitMessage,
    Codex.AppServer,
    Config,
    Linear.Issue,
    PromptBuilder,
    Tracker,
    Workflow,
    Workpad,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @prereview_codex_state_name "prereview (ai)"
  @review_codex_state_name "review (ai)"
  @test_codex_state_name "test (ai)"
  @implementation_handoff_state_name "Freigabe Implementierung"
  @review_handoff_state_name "Freigabe Review"
  @test_handoff_state_name "Merge (AI)"
  @merge_codex_state_name "merge (ai)"
  @merge_handoff_state_name "Review"
  @manual_in_progress_state_name "in arbeit"
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

      {:bootstrap_only, %Issue{} = manual_issue} ->
        bootstrap_manual_in_progress_issue(manual_issue, codex_update_recipient, worker_host)

      :manual_noop ->
        Logger.info("Skipping manual-only issue state for #{issue_context(issue)} state=#{inspect(issue.state)}")
        maybe_clear_review_autocommit_marker_for_existing_workspace(issue, worker_host)

      :proceed ->
        case Workspace.create_for_issue(issue, worker_host) do
          {:ok, workspace} ->
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

            try do
              with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                   :ok <- maybe_sync_issue_branch_name(issue, workspace, worker_host),
                   :ok <- maybe_prepare_workspace_for_issue_run(issue, workspace, worker_host, opts) do
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
      manual_in_progress_issue_state?(issue.state) ->
        {:bootstrap_only, issue}

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

  defp bootstrap_manual_in_progress_issue(%Issue{} = issue, codex_update_recipient, worker_host) do
    Logger.info("Bootstrapping workspace for manual in-progress issue #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        with :ok <- maybe_clear_review_autocommit_marker(issue, workspace, worker_host) do
          maybe_sync_issue_branch_name(issue, workspace, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
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

    case AppServer.start_session(workspace, worker_host: worker_host) do
      {:ok, session} ->
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
          do_run_codex_turns(run_context, issue, 1, :initial)
        after
          AppServer.stop_session(session)
        end

      {:error, reason} ->
        handle_run_error(reason, issue, turn_context)
    end
  end

  defp do_run_codex_turns(turn_context, issue, turn_number, previous_turn_outcome)
       when is_map(turn_context) do
    opts = turn_context.opts
    max_turns = turn_context.max_turns

    prompt =
      build_turn_prompt(
        issue,
        turn_context.workspace,
        opts,
        turn_number,
        max_turns,
        previous_turn_outcome
      )

    turn_context.app_session
    |> AppServer.run_turn(
      prompt,
      issue,
      on_message: codex_message_handler(turn_context.codex_update_recipient, issue)
    )
    |> handle_turn_result(turn_context, issue, turn_number)
  end

  defp handle_turn_result({:ok, turn_session}, turn_context, issue, turn_number) do
    Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}")

    issue
    |> continue_with_issue?(
      turn_context.issue_state_fetcher,
      turn_context.workspace,
      turn_context.worker_host
    )
    |> continue_turn(
      turn_context,
      turn_number,
      :completed,
      "after normal turn completion",
      "with issue still active"
    )
  end

  defp handle_turn_result({:error, {:turn_cancelled, reason}}, turn_context, issue, turn_number) do
    Logger.warning("Codex turn cancelled for #{issue_context(issue)} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}: #{inspect(reason)}")

    issue
    |> continue_after_cancelled_turn?(
      turn_context.issue_state_fetcher,
      turn_context.workspace,
      turn_context.worker_host
    )
    |> continue_turn(
      turn_context,
      turn_number,
      :cancelled,
      "after interrupted turn",
      "after interrupted turn"
    )
  end

  defp handle_turn_result({:error, reason}, turn_context, issue, _turn_number) do
    handle_run_error(reason, issue, turn_context)
  end

  defp continue_turn(
         {:continue, refreshed_issue},
         turn_context,
         turn_number,
         previous_turn_outcome,
         continuation_message,
         _max_turns_message
       )
       when turn_number < turn_context.max_turns do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} #{continuation_message} turn=#{turn_number}/#{turn_context.max_turns}")

    do_run_codex_turns(turn_context, refreshed_issue, turn_number + 1, previous_turn_outcome)
  end

  defp continue_turn(
         {:continue, refreshed_issue},
         turn_context,
         turn_number,
         _previous_turn_outcome,
         _continuation_message,
         max_turns_message
       ) do
    Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} #{max_turns_message}; returning control to orchestrator turn=#{turn_number}/#{turn_context.max_turns}")

    :ok
  end

  defp continue_turn(
         {:done, _refreshed_issue},
         _turn_context,
         _turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       ),
       do: :ok

  defp continue_turn(
         {:error, reason},
         _turn_context,
         _turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       ),
       do: {:error, reason}

  defp build_turn_prompt(issue, workspace, opts, 1, _max_turns, _previous_turn_outcome) do
    prompt_opts =
      opts
      |> Keyword.put_new(:session_mode, :orchestrated)
      |> Keyword.put(:active_repo_root, workspace)

    PromptBuilder.build_prompt(issue, prompt_opts)
  end

  defp build_turn_prompt(
         %Issue{} = issue,
         _workspace,
         _opts,
         turn_number,
         max_turns,
         previous_turn_outcome
       ) do
    Workflow.prompt_snippet("continuation_guidance", %{
      continuation_intro: continuation_intro(previous_turn_outcome),
      turn_number: turn_number,
      max_turns: max_turns,
      issue_state: issue.state
    })
  end

  defp continuation_intro(:cancelled) do
    Workflow.prompt_snippet("continuation_intro_cancelled")
  end

  defp continuation_intro(_previous_turn_outcome) do
    Workflow.prompt_snippet("continuation_intro_completed")
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

  defp continue_after_cancelled_turn?(
         %Issue{id: issue_id} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        with :ok <-
               maybe_clear_review_autocommit_marker_after_review_departure(
                 started_issue,
                 refreshed_issue,
                 workspace,
                 worker_host
               ) do
          continuation_status(refreshed_issue, :normal)
        end

      {:ok, []} ->
        {:done, started_issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_after_cancelled_turn?(
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
    result =
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

    with {:ok, %Issue{} = current_issue, continuation_mode} <- result,
         :ok <-
           maybe_clear_review_autocommit_marker_after_review_departure(
             started_issue,
             current_issue,
             workspace,
             worker_host
           ) do
      {:ok, current_issue, continuation_mode}
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
        {:ok, coerce_stale_issue_state(refreshed_issue, issue.state, fallback_state)}

      {:ok, []} ->
        {:ok, %{issue | state: fallback_state}}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp coerce_stale_issue_state(%Issue{} = refreshed_issue, previous_state, fallback_state)
       when is_binary(previous_state) and is_binary(fallback_state) do
    refreshed_state = normalize_issue_state(refreshed_issue.state)
    previous_state = normalize_issue_state(previous_state)
    normalized_fallback_state = normalize_issue_state(fallback_state)

    if refreshed_state == previous_state and normalized_fallback_state != previous_state do
      %{refreshed_issue | state: fallback_state}
    else
      refreshed_issue
    end
  end

  defp handle_run_error(reason, %Issue{} = issue, turn_context) when is_map(turn_context) do
    case maybe_clear_review_autocommit_marker_after_review_error(
           issue,
           turn_context.issue_state_fetcher,
           turn_context.workspace,
           turn_context.worker_host
         ) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:review_error_cleanup_failed, reason, cleanup_reason}}
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
    case review_workpad_handoff_status(issue) do
      :ready ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          resolve_review_handoff_state(issue, workspace, worker_host),
          :review_handoff_state_update_failed,
          "completed review issue",
          :stop
        )

      :blocked ->
        Logger.info("Keeping review issue in place because the workpad still has open review checklist items: #{issue_context(issue)}")
        {:ok, issue, :stop}

      {:error, reason} ->
        Logger.warning("Failed to inspect workpad review checklist before review handoff; keeping issue in current state: #{issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue, :stop}
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

  defp maybe_prepare_workspace_for_issue_run(%Issue{state: state} = issue, workspace, worker_host, _opts)
       when is_binary(state) and is_binary(workspace) do
    if review_codex_state?(state) do
      maybe_create_review_autocommit(issue, workspace, worker_host)
    else
      maybe_clear_review_autocommit_marker(issue, workspace, worker_host)
    end
  end

  defp maybe_prepare_workspace_for_issue_run(_issue, _workspace, _worker_host, _opts), do: :ok

  defp maybe_create_review_autocommit(%Issue{} = issue, workspace, worker_host) do
    case Workspace.prepare_review_autocommit(workspace, AutocommitMessage.build(issue, "Review (AI)"), worker_host) do
      {:ok, :already_recorded} ->
        Logger.info("Skipped review autocommit because this review stay was already prepared #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :clean} ->
        Logger.info("Recorded review autocommit marker for clean workspace #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :not_git_repo} ->
        Logger.info("Skipped review autocommit because the workspace is not a git repository #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :committed} ->
        Logger.info("Created review autocommit before first review turn #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed review autocommit before first review turn #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")
        {:error, {:review_autocommit_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker(%Issue{} = issue, workspace, worker_host) do
    case Workspace.clear_review_autocommit_marker(workspace, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to clear stale review autocommit marker before non-review run #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
        )

        {:error, {:review_autocommit_marker_clear_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker_for_existing_workspace(%Issue{} = issue, worker_host) do
    case Workspace.clear_review_autocommit_marker_for_existing_issue_workspace(issue, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clear stale review autocommit marker for manual issue #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")

        {:error, {:review_autocommit_marker_clear_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker_after_review_error(
         %Issue{} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    if review_codex_state?(started_issue.state) do
      case refetch_issue(started_issue, issue_state_fetcher, started_issue.state) do
        {:ok, %Issue{} = refreshed_issue} ->
          maybe_clear_review_autocommit_marker_after_review_departure(
            started_issue,
            refreshed_issue,
            workspace,
            worker_host
          )

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_clear_review_autocommit_marker_after_review_departure(
         %Issue{} = started_issue,
         %Issue{} = current_issue,
         workspace,
         worker_host
       ) do
    if review_codex_state?(started_issue.state) and not review_codex_state?(current_issue.state) do
      maybe_clear_review_autocommit_marker(current_issue, workspace, worker_host)
    else
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

  defp manual_in_progress_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @manual_in_progress_state_name
  end

  defp manual_in_progress_issue_state?(_state_name), do: false

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

  defp resolve_review_handoff_state(%Issue{} = issue, _workspace, _worker_host),
    do: resolve_next_handoff_state(issue)

  defp review_workpad_handoff_status(%Issue{id: issue_id}) when is_binary(issue_id) do
    with {:ok, comments} <- Tracker.fetch_issue_comment_bodies(issue_id) do
      comments
      |> Workpad.find_comment_body()
      |> review_workpad_status_from_body()
    end
  end

  defp review_workpad_handoff_status(_issue), do: :ready

  defp review_workpad_status_from_body(body) when is_binary(body) do
    case Workpad.section_checklist_status(body, "Review") do
      :closed -> :ready
      :open -> :blocked
      :missing -> :blocked
      :no_checklist -> :blocked
    end
  end

  defp review_workpad_status_from_body(_body), do: :blocked

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
