defmodule SymphonyElixir.WorktreeCommitMonitor do
  @moduledoc """
  Detects local worktree HEAD changes and runs the configured commit hook.
  """

  require Logger

  alias SymphonyElixir.{Config, HookRunner, RuntimePaths}

  @hook_name "on_worktree_commit"
  @cursor_file_name "symphony_worktree_commit_cursors.json"

  @type worktree_info :: %{
          workspace: Path.t(),
          branch: String.t() | nil,
          head: String.t()
        }

  @spec run() :: :ok
  def run do
    case Config.settings!().hooks.on_worktree_commit do
      nil ->
        :ok

      command ->
        do_run(command)
    end
  rescue
    error in [ArgumentError, File.Error] ->
      Logger.warning("Skipping worktree commit monitor: #{Exception.message(error)}")
      :ok
  end

  defp do_run(command) when is_binary(command) do
    source_repo = RuntimePaths.project_root()

    with {:ok, cursor_file} <- cursor_file_path(source_repo),
         {:ok, worktrees} <- managed_worktrees(source_repo),
         {:ok, cursors} <- load_cursors(cursor_file) do
      {updated_cursors, changed?} =
        reduce_worktrees(worktrees, prune_cursors(cursors, worktrees), command, source_repo)

      if changed? do
        :ok = persist_cursors(cursor_file, updated_cursors)
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("Skipping worktree commit monitor: #{inspect(reason)}")
        :ok
    end
  end

  defp reduce_worktrees(worktrees, initial_cursors, command, source_repo)
       when is_list(worktrees) and is_map(initial_cursors) do
    Enum.reduce(worktrees, {initial_cursors, false}, fn worktree, {acc, changed?} ->
      case maybe_run_hook(command, source_repo, worktree, Map.get(acc, worktree.workspace)) do
        {:ok, nil} ->
          {acc, changed?}

        {:ok, head} ->
          {Map.put(acc, worktree.workspace, head), true}

        {:error, reason} ->
          log_pending_retry(worktree, reason)
          {acc, changed?}
      end
    end)
  end

  defp log_pending_retry(worktree, reason) when is_map(worktree) do
    Logger.warning("Worktree commit hook retry pending workspace=#{worktree.workspace} branch=#{worktree.branch} head=#{worktree.head} reason=#{inspect(reason)}")
  end

  defp maybe_run_hook(_command, _source_repo, %{head: head}, head), do: {:ok, nil}

  defp maybe_run_hook(_command, _source_repo, worktree, nil) do
    Logger.debug("Seeding worktree commit cursor workspace=#{worktree.workspace} branch=#{worktree.branch} head=#{worktree.head}")

    {:ok, worktree.head}
  end

  defp maybe_run_hook(command, source_repo, worktree, previous_head) do
    env =
      RuntimePaths.builtin_env()
      |> Map.merge(%{
        "SYMPHONY_WORKSPACE" => worktree.workspace,
        "SYMPHONY_BRANCH_NAME" => worktree.branch || "",
        "SYMPHONY_PREV_HEAD_SHA" => previous_head,
        "SYMPHONY_HEAD_SHA" => worktree.head,
        "SYMPHONY_TARGET_BRANCH_NAME" => active_source_branch(source_repo) || ""
      })

    case HookRunner.run_local(
           command,
           worktree.workspace,
           @hook_name,
           env: env,
           timeout_ms: Config.settings!().hooks.timeout_ms,
           log_context: %{
             workspace: worktree.workspace,
             branch: worktree.branch,
             previous_head: previous_head,
             head: worktree.head,
             target_branch: env["SYMPHONY_TARGET_BRANCH_NAME"]
           }
         ) do
      :ok ->
        {:ok, worktree.head}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prune_cursors(cursors, worktrees) when is_map(cursors) and is_list(worktrees) do
    valid_workspaces =
      worktrees
      |> Enum.map(& &1.workspace)
      |> MapSet.new()

    Enum.reduce(cursors, %{}, fn {workspace, head}, acc ->
      if MapSet.member?(valid_workspaces, workspace) do
        Map.put(acc, workspace, head)
      else
        acc
      end
    end)
  end

  defp managed_worktrees(source_repo) when is_binary(source_repo) do
    workspace_root = Path.expand(Config.settings!().workspace.root)
    source_repo = Path.expand(source_repo)

    with {:ok, output} <- run_git(source_repo, ["worktree", "list", "--porcelain"]) do
      output
      |> parse_worktree_blocks()
      |> Enum.map(&Map.update!(&1, :workspace, fn path -> Path.expand(path) end))
      |> Enum.reject(&(&1.workspace == source_repo))
      |> Enum.filter(&managed_workspace?(&1.workspace, workspace_root))
      |> enrich_worktrees_with_heads()
    end
  end

  defp enrich_worktrees_with_heads(worktrees) when is_list(worktrees) do
    worktrees
    |> Enum.reduce([], fn %{workspace: workspace, branch: branch}, acc ->
      case current_head(workspace) do
        {:ok, head} ->
          [%{workspace: workspace, branch: branch, head: head} | acc]

        {:error, reason} ->
          Logger.warning("Skipping managed worktree with unreadable HEAD workspace=#{workspace} reason=#{inspect(reason)}")

          acc
      end
    end)
    |> Enum.reverse()
    |> then(&{:ok, &1})
  end

  defp parse_worktree_blocks(output) when is_binary(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.reduce([], fn block, acc ->
      case parse_worktree_block(block) do
        %{workspace: workspace} = metadata when is_binary(workspace) -> [metadata | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_worktree_block(block) when is_binary(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, metadata ->
      cond do
        String.starts_with?(line, "worktree ") ->
          Map.put(metadata, :workspace, String.trim_leading(line, "worktree "))

        String.starts_with?(line, "branch refs/heads/") ->
          Map.put(metadata, :branch, String.trim_leading(line, "branch refs/heads/"))

        true ->
          metadata
      end
    end)
  end

  defp managed_workspace?(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)

    String.starts_with?(expanded_workspace <> "/", expanded_root <> "/")
  end

  defp current_head(workspace) when is_binary(workspace) do
    case run_git(workspace, ["rev-parse", "HEAD"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:error, :empty_head}
          head -> {:ok, head}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp active_source_branch(source_repo) when is_binary(source_repo) do
    case run_git(source_repo, ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp cursor_file_path(source_repo) when is_binary(source_repo) do
    with {:ok, output} <- run_git(source_repo, ["rev-parse", "--git-common-dir"]) do
      common_dir =
        output
        |> String.trim()
        |> normalize_git_path(source_repo)

      {:ok, Path.join(common_dir, @cursor_file_name)}
    end
  end

  defp normalize_git_path(path, source_repo) when is_binary(path) and is_binary(source_repo) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.expand(path, source_repo)
    end
  end

  defp load_cursors(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"entries" => entries}} ->
            {:ok,
             entries
             |> Enum.reduce(%{}, fn
               {workspace, head}, acc when is_binary(workspace) and is_binary(head) ->
                 Map.put(acc, workspace, head)

               {_workspace, _head}, acc ->
                 acc
             end)}

          {:ok, _decoded} ->
            {:error, {:invalid_worktree_commit_cursors, path}}

          {:error, reason} ->
            {:error, {:invalid_worktree_commit_cursors, path, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:worktree_commit_cursors_unreadable, path, reason}}
    end
  end

  defp persist_cursors(path, cursors) when is_binary(path) and is_map(cursors) do
    payload = Jason.encode!(%{"version" => 1, "entries" => cursors}, pretty: true)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, payload <> "\n")
    :ok
  end

  defp run_git(repo, args) when is_binary(repo) and is_list(args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_command_failed, repo, status, output}}
    end
  end
end
