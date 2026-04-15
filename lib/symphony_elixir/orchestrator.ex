defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @worker_exit_finalize_drain_ms 250
  @idle_shutdown_message "Symphony nach Inaktivität beendet"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @cancel_state_name "abbruch (ai)"
  @in_arbeit_ai_state_name "in arbeit (ai)"
  @manual_in_progress_state_name "in arbeit"
  @canceled_terminal_state_name "Abgebrochen"
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :idle_shutdown_ms,
      :idle_shutdown_ms_override,
      :last_activity_at_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :shutdown_fun,
      :output_fun,
      shutdown_requested: false,
      running: %{},
      completed: MapSet.new(),
      completed_states: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    idle_shutdown_ms_override = Keyword.get(opts, :idle_shutdown_ms)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      idle_shutdown_ms: idle_shutdown_ms_override || config.polling.idle_shutdown_ms,
      idle_shutdown_ms_override: idle_shutdown_ms_override,
      last_activity_at_ms: now_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      shutdown_fun: Keyword.get(opts, :shutdown_fun, &default_shutdown/0),
      output_fun: Keyword.get(opts, :output_fun, &IO.puts/1),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    previous_state = state
    state = maybe_dispatch(state)
    state = maybe_touch_activity_for_state_change(previous_state, state)
    state = maybe_request_idle_shutdown(state)
    state = if state.shutdown_requested, do: state, else: schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        state =
          case reason do
            :normal ->
              schedule_running_entry_finalization(state, issue_id, Map.get(running, issue_id), reason)

            _ ->
              {running_entry, state} = pop_running_entry(state, issue_id)
              state = record_session_completion_totals(state, running_entry)
              session_id = running_entry_session_id(running_entry)

              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              state =
                schedule_issue_retry(state, issue_id, next_attempt, %{
                  identifier: running_entry.identifier,
                  error: "agent exited: #{inspect(reason)}",
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path),
                  recovered_turn_context: recoverable_turn_context(running_entry, reason)
                })

              Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")
              state
          end
          |> touch_activity()

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)} |> touch_activity()}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)} |> touch_activity()}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          case handle_retry_issue(state, issue_id, attempt, metadata) do
            {:noreply, next_state} -> {:noreply, touch_activity(next_state)}
          end

        :missing ->
          {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:finalize_running_issue_exit, issue_id, finalize_token}, %{running: running} = state)
      when is_binary(issue_id) and is_reference(finalize_token) do
    case Map.get(running, issue_id) do
      %{exit_finalize_token: ^finalize_token} ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        exit_reason = Map.get(running_entry, :exit_reason, :normal)
        running_entry = clear_running_entry_finalize_state(running_entry)
        session_id = running_entry_session_id(running_entry)
        state = record_session_completion_totals(state, running_entry)

        state =
          case exit_reason do
            :normal ->
              handle_normal_issue_completion(state, issue_id, session_id, running_entry)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(exit_reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(exit_reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                recovered_turn_context: recoverable_turn_context(running_entry, exit_reason)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(exit_reason)}")

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      state = retain_visible_completed_states(state, issues)

      if available_slots(state) > 0 do
        choose_issues(state, issues)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      cancel_issue_state?(issue.state) ->
        Logger.info("Issue moved to cancel state: #{issue_context(issue)} state=#{issue.state}; aborting workflow and cleaning workspace")

        cancel_issue_workflow(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      task_supervisor when is_pid(task_supervisor) ->
        case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Process.exit(pid, :shutdown)
        end

      _ ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(state, issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      cond do
        cancel_issue_state?(issue.state) ->
          cancel_issue_workflow(state_acc, issue)

        should_dispatch_issue?(issue, state_acc, active_states, terminal_states) ->
          dispatch_issue(state_acc, issue)

        true ->
          state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, completed_states: completed_states} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !blocked_issue_in_dispatch_state?(issue, terminal_states) and
      !completed_in_current_state?(issue, completed_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !cancel_issue_state?(state_name) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp blocked_issue_in_dispatch_state?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    blocked_by_respected_issue_state?(issue_state) and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp blocked_issue_in_dispatch_state?(_issue, _terminal_states), do: false

  defp todo_issue_state?(state_name) when is_binary(state_name) do
    String.starts_with?(normalize_issue_state(state_name), "todo")
  end

  defp blocked_by_respected_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    todo_issue_state?(normalized_state) or normalized_state == @in_arbeit_ai_state_name
  end

  defp cancel_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @cancel_state_name
  end

  defp cancel_issue_state?(_state_name), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.concat([@manual_in_progress_state_name])
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp manual_in_progress_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @manual_in_progress_state_name
  end

  defp manual_in_progress_issue_state?(_state_name), do: false

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         run_opts \\ []
       ) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, run_opts)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, run_opts) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, run_opts)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, run_opts) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             Keyword.merge(run_opts, attempt: attempt, worker_host: worker_host)
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            recovered_turn_context: nil,
            review_subagent_call_ids: MapSet.new(),
            review_subagent_ids: MapSet.new(),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id, issue_state) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        completed_states: put_completed_state(state.completed_states, issue_id, issue_state),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    recovered_turn_context = pick_retry_recovered_turn_context(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            recovered_turn_context: recovered_turn_context
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          recovered_turn_context: Map.get(retry_entry, :recovered_turn_context)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      cancel_issue_state?(issue.state) ->
        Logger.info("Issue state is cancel requested: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; aborting workflow and cleaning workspace")

        {:noreply, cancel_issue_workflow(state, issue, metadata[:worker_host])}

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp cancel_issue_workflow(%State{} = state, %Issue{} = issue, cleanup_worker_host \\ nil) do
    state =
      case Map.get(state.running, issue.id) do
        %{identifier: _identifier} ->
          state
          |> terminate_running_issue(issue.id, true)
          |> clear_issue_tracking(issue.id)

        _ ->
          cleanup_issue_workspace(issue.identifier, cleanup_worker_host)
          clear_issue_tracking(state, issue.id)
      end

    case Tracker.update_issue_state(issue.id, @canceled_terminal_state_name) do
      :ok ->
        Logger.info("Issue cancel cleanup completed: #{issue_context(issue)} next_state=#{@canceled_terminal_state_name}")

      {:error, reason} ->
        Logger.warning("Issue cancel cleanup completed but state transition failed: #{issue_context(issue)} next_state=#{@canceled_terminal_state_name} reason=#{inspect(reason)}")
    end

    state
  end

  defp clear_issue_tracking(%State{} = state, issue_id) when is_binary(issue_id) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        completed: MapSet.delete(state.completed, issue_id),
        completed_states: Map.delete(state.completed_states, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply,
       dispatch_issue(
         state,
         issue,
         attempt,
         metadata[:worker_host],
         recovered_turn_context_run_opts(metadata)
       )}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp handle_normal_issue_completion(%State{} = state, issue_id, session_id, running_entry)
       when is_binary(issue_id) and is_map(running_entry) do
    if manual_in_progress_issue_state?(running_entry.issue.state) do
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; manual in-progress bootstrap finished without continuation")

      state
      |> complete_issue(issue_id, running_entry.issue.state)
      |> release_issue_claim(issue_id)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id, running_entry.issue.state)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        recovered_turn_context: Map.get(running_entry, :recovered_turn_context)
      })
    end
  end

  defp completed_in_current_state?(%Issue{id: issue_id, state: issue_state}, completed_states)
       when is_binary(issue_id) and is_binary(issue_state) and is_map(completed_states) do
    Map.get(completed_states, issue_id) == normalize_issue_state(issue_state)
  end

  defp completed_in_current_state?(_issue, _completed_states), do: false

  defp put_completed_state(completed_states, issue_id, issue_state)
       when is_map(completed_states) and is_binary(issue_id) and is_binary(issue_state) do
    Map.put(completed_states, issue_id, normalize_issue_state(issue_state))
  end

  defp put_completed_state(completed_states, _issue_id, _issue_state) when is_map(completed_states),
    do: completed_states

  defp retain_visible_completed_states(%State{} = state, issues) when is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    completed_states =
      Enum.reduce(state.completed_states, %{}, fn {issue_id, normalized_state}, acc ->
        if MapSet.member?(visible_issue_ids, issue_id) do
          Map.put(acc, issue_id, normalized_state)
        else
          acc
        end
      end)

    completed =
      Enum.reduce(state.completed, MapSet.new(), fn issue_id, acc ->
        if MapSet.member?(visible_issue_ids, issue_id) do
          MapSet.put(acc, issue_id)
        else
          acc
        end
      end)

    %{state | completed_states: completed_states, completed: completed}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp schedule_running_entry_finalization(%State{} = state, issue_id, running_entry, reason)
       when is_binary(issue_id) and is_map(running_entry) do
    finalize_token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:finalize_running_issue_exit, issue_id, finalize_token},
        @worker_exit_finalize_drain_ms
      )

    updated_running_entry =
      running_entry
      |> cancel_running_entry_finalize_timer()
      |> Map.put(:exit_reason, reason)
      |> Map.put(:exit_finalize_token, finalize_token)
      |> Map.put(:exit_finalize_timer_ref, timer_ref)

    %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
  end

  defp schedule_running_entry_finalization(%State{} = state, _issue_id, _running_entry, _reason),
    do: state

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_recovered_turn_context(previous_retry, metadata) do
    metadata[:recovered_turn_context] || Map.get(previous_retry, :recovered_turn_context)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp recovered_turn_context_run_opts(%{recovered_turn_context: context}) when is_binary(context) do
    [recovered_turn_context: context]
  end

  defp recovered_turn_context_run_opts(_metadata), do: []

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    existing_session_id = Map.get(running_entry, :session_id)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    review_subagent_call_ids =
      review_subagent_call_ids_for_update(running_entry, existing_session_id, update)

    review_subagent_ids =
      review_subagent_ids_for_update(
        running_entry,
        existing_session_id,
        update,
        review_subagent_call_ids
      )

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(existing_session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, existing_session_id, update),
        review_subagent_call_ids: review_subagent_call_ids,
        review_subagent_ids: review_subagent_ids,
        recovered_turn_context: recovered_turn_context_for_update(running_entry, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp recovered_turn_context_for_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    extract_review_subagent_completion_text(running_entry, update) ||
      Map.get(running_entry, :recovered_turn_context)
  end

  defp review_subagent_call_ids_for_update(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    running_entry
    |> review_subagent_call_ids_base(existing_session_id, update)
    |> MapSet.union(extract_review_subagent_call_ids(update))
  end

  defp review_subagent_ids_for_update(
         running_entry,
         existing_session_id,
         update,
         review_subagent_call_ids
       )
       when is_map(running_entry) and is_map(update) do
    running_entry
    |> review_subagent_ids_base(existing_session_id, update)
    |> MapSet.union(extract_review_subagent_ids(update, review_subagent_call_ids))
  end

  defp recoverable_turn_context(running_entry, _reason) when is_map(running_entry) do
    Map.get(running_entry, :recovered_turn_context)
  end

  defp review_subagent_call_ids_base(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    if reset_review_subagent_tracking?(existing_session_id, update) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:review_subagent_call_ids, MapSet.new())
      |> normalize_review_subagent_call_ids()
    end
  end

  defp review_subagent_ids_base(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    if reset_review_subagent_tracking?(existing_session_id, update) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()
    end
  end

  defp reset_review_subagent_tracking?(existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(session_id) do
    session_id != existing_session_id
  end

  defp reset_review_subagent_tracking?(_existing_session_id, _update), do: false

  defp extract_review_subagent_completion_text(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    if review_codex_state_for_running_entry?(running_entry) do
      extract_subagent_completion_text(running_entry, update)
    end
  end

  defp extract_subagent_completion_text(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    extract_subagent_completion_from_tagged_notification_candidates(running_entry, update) ||
      extract_subagent_completion_from_wait_agent_update(running_entry, update)
  end

  defp extract_review_subagent_call_ids(update) when is_map(update) do
    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.reduce(MapSet.new(), fn value, ids ->
      Enum.reduce(extract_review_subagent_call_ids_from_event(value), ids, fn id, acc ->
        MapSet.put(acc, id)
      end)
    end)
  end

  defp extract_review_subagent_call_ids_from_event(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_call_ids_from_event(decoded)
      _ -> []
    end
  end

  defp extract_review_subagent_call_ids_from_event(%{
         "method" => "item/tool/call",
         "params" => params
       }) do
    extract_review_subagent_call_ids_from_tool_call_params(params)
  end

  defp extract_review_subagent_call_ids_from_event(%{method: "item/tool/call", params: params}) do
    extract_review_subagent_call_ids_from_tool_call_params(params)
  end

  defp extract_review_subagent_call_ids_from_event(_value), do: []

  defp extract_review_subagent_call_ids_from_tool_call_params(params) when is_map(params) do
    tool_name =
      Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
        Map.get(params, :name)

    call_id = Map.get(params, "callId") || Map.get(params, :callId)
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments)

    if tool_name == "spawn_agent" and valid_review_subagent_call_id?(call_id) and
         review_subagent_request?(arguments) do
      [String.trim(call_id)]
    else
      []
    end
  end

  defp extract_review_subagent_call_ids_from_tool_call_params(_params), do: []

  defp extract_review_subagent_ids(update, review_subagent_call_ids) when is_map(update) do
    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.reduce(MapSet.new(), fn value, ids ->
      Enum.reduce(extract_review_subagent_ids_from_event(value, review_subagent_call_ids), ids, fn
        id, acc ->
          MapSet.put(acc, id)
      end)
    end)
  end

  defp extract_review_subagent_ids_from_event(value, review_subagent_call_ids) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_ids_from_event(decoded, review_subagent_call_ids)
      _ -> []
    end
  end

  defp extract_review_subagent_ids_from_event(
         %{"method" => "item/completed", "params" => %{"item" => item}},
         review_subagent_call_ids
       ) do
    extract_review_subagent_ids_from_item(item, review_subagent_call_ids)
  end

  defp extract_review_subagent_ids_from_event(
         %{method: "item/completed", params: %{item: item}},
         review_subagent_call_ids
       ) do
    extract_review_subagent_ids_from_item(item, review_subagent_call_ids)
  end

  defp extract_review_subagent_ids_from_event(_value, _review_subagent_call_ids), do: []

  defp extract_review_subagent_ids_from_item(item, review_subagent_call_ids) when is_map(item) do
    item_type = Map.get(item, "type") || Map.get(item, :type)

    tool_name =
      Map.get(item, "tool") || Map.get(item, :tool) || Map.get(item, "name") || Map.get(item, :name)

    if item_type == "function_call_output" and tool_name == "spawn_agent" and
         trusted_review_subagent_spawn_output?(item, review_subagent_call_ids) do
      item
      |> Map.get("output", Map.get(item, :output))
      |> extract_review_subagent_ids_from_spawn_output()
    else
      []
    end
  end

  defp extract_review_subagent_ids_from_item(_item, _review_subagent_call_ids), do: []

  defp extract_review_subagent_ids_from_spawn_output(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_ids_from_spawn_output(decoded)
      _ -> []
    end
  end

  defp extract_review_subagent_ids_from_spawn_output(value) when is_map(value) do
    value
    |> candidate_review_subagent_id()
    |> case do
      id when is_binary(id) -> [id]
      _ -> []
    end
  end

  defp candidate_review_subagent_id(value) when is_map(value) do
    [
      Map.get(value, "id"),
      Map.get(value, :id),
      Map.get(value, "agent_id"),
      Map.get(value, :agent_id),
      Map.get(value, "agent_path"),
      Map.get(value, :agent_path)
    ]
    |> Enum.find(&valid_review_subagent_id?/1)
  end

  defp valid_review_subagent_id?(value) when is_binary(value) do
    trimmed = String.trim(value)

    trimmed != "" and
      (String.contains?(trimmed, ["-", "_", "/"]) or String.match?(trimmed, ~r/\d/u))
  end

  defp valid_review_subagent_id?(_value), do: false

  defp valid_review_subagent_call_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_review_subagent_call_id?(_value), do: false

  defp normalize_review_subagent_call_ids(value) when is_struct(value, MapSet), do: value

  defp normalize_review_subagent_call_ids(value) when is_list(value) do
    value
    |> Enum.filter(&valid_review_subagent_call_id?/1)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  defp normalize_review_subagent_call_ids(_value), do: MapSet.new()

  defp normalize_review_subagent_ids(value) when is_struct(value, MapSet), do: value

  defp normalize_review_subagent_ids(value) when is_list(value) do
    value
    |> Enum.filter(&valid_review_subagent_id?/1)
    |> MapSet.new()
  end

  defp normalize_review_subagent_ids(_value), do: MapSet.new()

  defp review_subagent_request?(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> review_subagent_request?(decoded)
      _ -> false
    end
  end

  defp review_subagent_request?(value) when is_map(value) do
    fork_context = Map.get(value, "fork_context", Map.get(value, :fork_context))
    agent_type = Map.get(value, "agent_type") || Map.get(value, :agent_type)
    review_text = review_subagent_request_text(value)
    normalized_text = String.downcase(review_text)

    fork_context == false and
      default_review_subagent_agent_type?(agent_type) and
      String.contains?(normalized_text, "origin/main") and
      String.contains?(normalized_text, "worktree") and
      (String.contains?(normalized_text, "read-only") or
         String.contains?(normalized_text, "read only")) and
      String.contains?(review_text, "Findings:") and
      String.contains?(review_text, "Keine Findings.")
  end

  defp review_subagent_request?(_value), do: false

  defp default_review_subagent_agent_type?(nil), do: true
  defp default_review_subagent_agent_type?(""), do: true
  defp default_review_subagent_agent_type?(:default), do: true
  defp default_review_subagent_agent_type?("default"), do: true
  defp default_review_subagent_agent_type?(_value), do: false

  defp review_subagent_request_text(value) when is_map(value) do
    [Map.get(value, "message") || Map.get(value, :message) | review_subagent_request_item_texts(value)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  defp review_subagent_request_item_texts(value) when is_map(value) do
    value
    |> Map.get("items", Map.get(value, :items, []))
    |> List.wrap()
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp trusted_review_subagent_spawn_output?(item, review_subagent_call_ids)
       when is_map(item) and is_struct(review_subagent_call_ids, MapSet) do
    MapSet.size(review_subagent_call_ids) > 0 and
      Enum.any?(candidate_review_subagent_call_ids_from_item(item), fn call_id ->
        MapSet.member?(review_subagent_call_ids, call_id)
      end)
  end

  defp trusted_review_subagent_spawn_output?(_item, _review_subagent_call_ids), do: false

  defp candidate_review_subagent_call_ids_from_item(item) when is_map(item) do
    [
      Map.get(item, "id"),
      Map.get(item, :id),
      Map.get(item, "callId"),
      Map.get(item, :callId),
      Map.get(item, "call_id"),
      Map.get(item, :call_id)
    ]
    |> Enum.filter(&valid_review_subagent_call_id?/1)
    |> Enum.map(&String.trim/1)
  end

  defp extract_subagent_completion_from_tagged_notification_candidates(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    review_subagent_ids =
      running_entry
      |> Map.get(:review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()

    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.find_value(&extract_subagent_completion_from_tagged_notification_event(&1, review_subagent_ids))
  end

  defp extract_subagent_completion_from_tagged_notification_candidates(_running_entry, _update),
    do: nil

  defp extract_subagent_completion_from_tagged_notification_event(value, review_subagent_ids)
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        extract_subagent_completion_from_tagged_notification_event(decoded, review_subagent_ids)

      _ ->
        nil
    end
  end

  defp extract_subagent_completion_from_tagged_notification_event(
         %{
           "method" => "codex/event/user_message",
           "params" => %{"msg" => msg}
         },
         review_subagent_ids
       ) do
    extract_subagent_completion_from_user_message(msg, review_subagent_ids)
  end

  defp extract_subagent_completion_from_tagged_notification_event(
         %{
           method: "codex/event/user_message",
           params: %{msg: msg}
         },
         review_subagent_ids
       ) do
    extract_subagent_completion_from_user_message(msg, review_subagent_ids)
  end

  defp extract_subagent_completion_from_tagged_notification_event(_value, _review_subagent_ids),
    do: nil

  defp extract_subagent_completion_from_user_message(msg, review_subagent_ids) when is_map(msg) do
    with content when is_list(content) <- user_message_content(msg),
         tagged_text when is_binary(tagged_text) <- find_tagged_subagent_notification_text(content),
         {:ok, payload} <- decode_tagged_payload(tagged_text, "subagent_notification"),
         completion when is_binary(completion) <-
           valid_subagent_completion_from_payload(payload, review_subagent_ids),
         trimmed when trimmed != "" <- String.trim(completion) do
      trimmed
    else
      _ -> nil
    end
  end

  defp extract_subagent_completion_from_user_message(_msg, _review_subagent_ids), do: nil

  defp extract_subagent_completion_from_wait_agent_update(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    review_subagent_ids =
      running_entry
      |> Map.get(:review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()

    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.find_value(&extract_subagent_completion_from_wait_agent_event(&1, review_subagent_ids))
  end

  defp extract_subagent_completion_from_wait_agent_update(_running_entry, _update), do: nil

  defp extract_subagent_completion_from_wait_agent_event(value, review_subagent_ids)
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_subagent_completion_from_wait_agent_event(decoded, review_subagent_ids)
      _ -> nil
    end
  end

  defp extract_subagent_completion_from_wait_agent_event(
         %{"method" => "item/completed", "params" => %{"item" => item}},
         review_subagent_ids
       ) do
    extract_subagent_completion_from_wait_agent_item(item, review_subagent_ids)
  end

  defp extract_subagent_completion_from_wait_agent_event(
         %{method: "item/completed", params: %{item: item}},
         review_subagent_ids
       ) do
    extract_subagent_completion_from_wait_agent_item(item, review_subagent_ids)
  end

  defp extract_subagent_completion_from_wait_agent_event(_value, _review_subagent_ids), do: nil

  defp extract_subagent_completion_from_wait_agent_item(item, review_subagent_ids) when is_map(item) do
    item_type = Map.get(item, "type") || Map.get(item, :type)
    tool_name = Map.get(item, "tool") || Map.get(item, :tool) || Map.get(item, "name") || Map.get(item, :name)

    if item_type == "function_call_output" and tool_name == "wait_agent" do
      item
      |> Map.get("output", Map.get(item, :output))
      |> extract_subagent_completion_from_wait_agent_result(review_subagent_ids)
    end
  end

  defp extract_subagent_completion_from_wait_agent_item(_item, _review_subagent_ids), do: nil

  defp extract_subagent_completion_from_wait_agent_result(value, review_subagent_ids)
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_subagent_completion_from_wait_agent_result(decoded, review_subagent_ids)
      _ -> nil
    end
  end

  defp extract_subagent_completion_from_wait_agent_result(%{"timed_out" => true}, _review_subagent_ids),
    do: nil

  defp extract_subagent_completion_from_wait_agent_result(%{timed_out: true}, _review_subagent_ids),
    do: nil

  defp extract_subagent_completion_from_wait_agent_result(%{"status" => status}, review_subagent_ids)
       when is_map(status) do
    extract_subagent_completion_from_wait_agent_status(status, review_subagent_ids)
  end

  defp extract_subagent_completion_from_wait_agent_result(%{status: status}, review_subagent_ids)
       when is_map(status) do
    extract_subagent_completion_from_wait_agent_status(status, review_subagent_ids)
  end

  defp extract_subagent_completion_from_wait_agent_result(_value, _review_subagent_ids), do: nil

  defp extract_subagent_completion_from_wait_agent_status(status, review_subagent_ids)
       when is_map(status) and is_struct(review_subagent_ids, MapSet) do
    Enum.find_value(status, fn
      {agent_id, entry} ->
        extract_subagent_completion_from_wait_agent_status_entry(
          agent_id,
          entry,
          review_subagent_ids
        )

      _ ->
        nil
    end)
  end

  defp extract_subagent_completion_from_wait_agent_status(_status, _review_subagent_ids), do: nil

  defp extract_subagent_completion_from_wait_agent_status_entry(
         agent_id,
         %{"completed" => completion},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp extract_subagent_completion_from_wait_agent_status_entry(
         agent_id,
         %{completed: completion},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp extract_subagent_completion_from_wait_agent_status_entry(
         _agent_id,
         _entry,
         _review_subagent_ids
       ),
       do: nil

  defp review_subagent_id_matches?(review_subagent_ids, agent_id)
       when is_struct(review_subagent_ids, MapSet) and is_binary(agent_id) do
    MapSet.size(review_subagent_ids) > 0 and MapSet.member?(review_subagent_ids, agent_id)
  end

  defp review_subagent_id_matches?(_review_subagent_ids, _agent_id), do: false

  defp valid_recovered_review_completion(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.starts_with?(trimmed, "Findings:") -> trimmed
      String.starts_with?(trimmed, "Keine Findings.") -> trimmed
      true -> nil
    end
  end

  defp review_codex_state_for_running_entry?(%{issue: %{state: state_name}})
       when is_binary(state_name) do
    normalize_issue_state(state_name) == "review (ai)"
  end

  defp review_codex_state_for_running_entry?(_running_entry), do: false

  defp find_tagged_subagent_notification_text(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "input_text", "text" => text} when is_binary(text) ->
        find_tagged_text(text, "subagent_notification")

      %{type: "input_text", text: text} when is_binary(text) ->
        find_tagged_text(text, "subagent_notification")

      _ ->
        nil
    end)
  end

  defp find_tagged_subagent_notification_text(_content), do: nil

  defp find_tagged_text(value, tag) when is_binary(value) and is_binary(tag) do
    trimmed_value = String.trim(value)
    open_tag = "<#{tag}>"
    close_tag = "</#{tag}>"
    payload_length = byte_size(trimmed_value) - byte_size(open_tag) - byte_size(close_tag)

    with true <- String.starts_with?(trimmed_value, open_tag),
         true <- String.ends_with?(trimmed_value, close_tag),
         true <- payload_length >= 0 do
      open_count = String.split(trimmed_value, open_tag) |> length() |> Kernel.-(1)
      close_count = String.split(trimmed_value, close_tag) |> length() |> Kernel.-(1)

      if open_count == 1 and close_count == 1 do
        trimmed_value
      end
    else
      _ -> nil
    end
  end

  defp find_tagged_text(_value, _tag), do: nil

  defp user_message_content(%{"payload" => %{"content" => content}}) when is_list(content), do: content
  defp user_message_content(%{payload: %{content: content}}) when is_list(content), do: content
  defp user_message_content(%{"content" => content}) when is_list(content), do: content
  defp user_message_content(%{content: content}) when is_list(content), do: content
  defp user_message_content(_msg), do: nil

  defp decode_tagged_payload(text, tag) when is_binary(text) and is_binary(tag) do
    trimmed_text = String.trim(text)
    open_tag = "<#{tag}>"
    close_tag = "</#{tag}>"

    with true <- String.starts_with?(trimmed_text, open_tag),
         true <- String.ends_with?(trimmed_text, close_tag) do
      payload_length = byte_size(trimmed_text) - byte_size(open_tag) - byte_size(close_tag)

      trimmed_text
      |> String.slice(byte_size(open_tag), payload_length)
      |> String.trim()
      |> Jason.decode()
    else
      _ -> :error
    end
  end

  defp valid_subagent_completion_from_payload(
         %{"agent_path" => agent_path, "status" => %{"completed" => completion}},
         review_subagent_ids
       )
       when is_binary(agent_path) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_path) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{agent_path: agent_path, status: %{completed: completion}},
         review_subagent_ids
       )
       when is_binary(agent_path) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_path) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{"agent_id" => agent_id, "status" => %{"completed" => completion}},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{agent_id: agent_id, status: %{completed: completion}},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(_payload, _review_subagent_ids), do: nil

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp cancel_running_entry_finalize_timer(%{exit_finalize_timer_ref: timer_ref} = running_entry)
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    Map.delete(running_entry, :exit_finalize_timer_ref)
  end

  defp cancel_running_entry_finalize_timer(running_entry), do: running_entry

  defp clear_running_entry_finalize_state(running_entry) when is_map(running_entry) do
    running_entry
    |> cancel_running_entry_finalize_timer()
    |> Map.delete(:exit_reason)
    |> Map.delete(:exit_finalize_token)
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        idle_shutdown_ms: state.idle_shutdown_ms_override || config.polling.idle_shutdown_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp maybe_touch_activity_for_state_change(%State{} = previous_state, %State{} = next_state) do
    if activity_state_changed?(previous_state, next_state) do
      touch_activity(next_state)
    else
      next_state
    end
  end

  defp activity_state_changed?(%State{} = previous_state, %State{} = next_state) do
    previous_state.running != next_state.running or
      previous_state.retry_attempts != next_state.retry_attempts or
      previous_state.claimed != next_state.claimed or
      previous_state.completed != next_state.completed or
      previous_state.completed_states != next_state.completed_states
  end

  defp maybe_request_idle_shutdown(%State{shutdown_requested: true} = state), do: state

  defp maybe_request_idle_shutdown(%State{idle_shutdown_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms <= 0,
       do: state

  defp maybe_request_idle_shutdown(%State{} = state) do
    cond do
      map_size(state.running) > 0 ->
        state

      map_size(state.retry_attempts) > 0 ->
        state

      true ->
        elapsed_ms = System.monotonic_time(:millisecond) - state.last_activity_at_ms

        if elapsed_ms >= state.idle_shutdown_ms do
          request_idle_shutdown(state, elapsed_ms)
        else
          state
        end
    end
  end

  defp request_idle_shutdown(%State{} = state, elapsed_ms) when is_integer(elapsed_ms) do
    Logger.info("Symphony idle shutdown requested idle_ms=#{elapsed_ms}")
    state.output_fun.(@idle_shutdown_message)
    spawn(fn -> state.shutdown_fun.() end)
    %{state | shutdown_requested: true, next_poll_due_at_ms: nil}
  end

  defp touch_activity(%State{} = state) do
    %{state | last_activity_at_ms: System.monotonic_time(:millisecond)}
  end

  defp default_shutdown do
    Application.stop(:symphony_elixir)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !blocked_issue_in_dispatch_state?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running = Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
