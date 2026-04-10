defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Close PRs, delete matching branches, and remove the linked worktree"

  @moduledoc """
  Closes open pull requests for the current Git branch, deletes the matching
  remote and local branches, and removes the linked worktree.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
      mix workspace.before_remove --workspace /path/to/worktree --source-repo /path/to/source-repo
  """

  @default_repo "openai/symphony"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string, source_repo: :string, workspace: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        workspace = normalize_optional_path(opts[:workspace])
        source_repo = normalize_optional_path(opts[:source_repo])
        cleanup_target = resolve_cleanup_target(workspace, source_repo)
        repo = opts[:repo] || current_repo_slug(cleanup_target_workspace(cleanup_target)) || @default_repo

        branch =
          opts[:branch] ||
            cleanup_target_branch(cleanup_target) ||
            current_branch_without_overrides(workspace, source_repo)

        maybe_close_open_pull_requests(repo, branch)
        maybe_remove_current_worktree(cleanup_target)
    end
  end

  defp maybe_close_open_pull_requests(_repo, nil), do: :ok

  defp maybe_close_open_pull_requests(repo, branch) do
    if gh_available?() and gh_authenticated?() do
      repo
      |> list_open_pull_request_numbers(branch)
      |> Enum.each(&close_pull_request(repo, branch, &1))
    end

    :ok
  end

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request(repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the Linear issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp maybe_remove_current_worktree({:error, _reason}), do: :ok

  defp maybe_remove_current_worktree({:ok, %{workspace: workspace, source_repo: source_repo, branch: branch}}) do
    original_cwd = File.cwd()

    case File.cd(source_repo) do
      :ok ->
        try do
          maybe_delete_remote_branch(source_repo, branch)
          maybe_delete_local_branch_after_worktree_removal(source_repo, workspace, branch)
          prune_worktrees(source_repo)
        after
          restore_original_cwd(original_cwd, source_repo)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to change directory to #{source_repo} before removing current Git worktree: #{inspect(reason)}")
    end

    :ok
  end

  defp resolve_cleanup_target(workspace_override, source_repo_override) do
    with {:ok, workspace} <- current_workspace(workspace_override),
         {:ok, source_repo} <- current_worktree_source_repo(workspace, source_repo_override),
         {:ok, metadata} <- current_worktree_metadata(source_repo, workspace) do
      {:ok, %{workspace: workspace, source_repo: source_repo, branch: Map.get(metadata, :branch)}}
    end
  end

  defp cleanup_target_workspace({:ok, %{workspace: workspace}}), do: workspace
  defp cleanup_target_workspace(_cleanup_target), do: nil

  defp cleanup_target_branch({:ok, %{branch: branch}}), do: branch
  defp cleanup_target_branch(_cleanup_target), do: nil

  defp current_branch_without_overrides(nil, nil), do: current_branch(nil)
  defp current_branch_without_overrides(_workspace_override, _source_repo_override), do: nil

  defp maybe_delete_remote_branch(_source_repo, nil), do: :ok

  defp maybe_delete_remote_branch(source_repo, branch)
       when is_binary(source_repo) and is_binary(branch) do
    case remote_branch_exists?(source_repo, branch) do
      true ->
        delete_remote_branch(source_repo, branch)

      false ->
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to check remote branch #{branch} in #{source_repo}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp remote_branch_exists?(source_repo, branch) do
    case run_command("git", ["-C", source_repo, "ls-remote", "--exit-code", "--heads", "origin", branch]) do
      {:ok, _output} -> true
      {:error, {2, _output}} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_remote_branch(source_repo, branch) do
    case run_command("git", ["-C", source_repo, "push", "origin", "--delete", branch]) do
      {:ok, _output} ->
        Mix.shell().info("Deleted remote branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)
        Mix.shell().error("Failed to delete remote branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp maybe_delete_local_branch_after_worktree_removal(source_repo, workspace, branch) do
    case remove_worktree(source_repo, workspace) do
      :ok -> maybe_delete_local_branch(source_repo, branch)
      :error -> :ok
    end
  end

  defp maybe_delete_local_branch(_source_repo, nil), do: :ok

  defp maybe_delete_local_branch(source_repo, branch)
       when is_binary(source_repo) and is_binary(branch) do
    case local_branch_exists?(source_repo, branch) do
      true ->
        delete_local_branch(source_repo, branch)

      false ->
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to check local branch #{branch} in #{source_repo}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp local_branch_exists?(source_repo, branch) do
    case run_command("git", ["-C", source_repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _output} -> true
      {:error, {1, _output}} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_local_branch(source_repo, branch) do
    case run_command("git", ["-C", source_repo, "branch", "-D", branch]) do
      {:ok, _output} ->
        Mix.shell().info("Deleted local branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)
        Mix.shell().error("Failed to delete local branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp current_workspace(workspace) when is_binary(workspace), do: {:ok, workspace}

  defp current_workspace(nil) do
    case run_command("git", ["rev-parse", "--show-toplevel"]) do
      {:ok, output} ->
        case output |> String.trim() |> normalize_absolute_path() do
          nil -> {:error, :workspace_unavailable}
          workspace -> {:ok, workspace}
        end

      {:error, _reason} ->
        {:error, :workspace_unavailable}
    end
  end

  defp current_worktree_source_repo(_workspace, source_repo) when is_binary(source_repo), do: {:ok, source_repo}

  defp current_worktree_source_repo(workspace, nil) do
    with {:ok, common_dir} <- git_absolute_path(["rev-parse", "--git-common-dir"], workspace),
         {:ok, absolute_git_dir} <- git_absolute_path(["rev-parse", "--absolute-git-dir"], workspace),
         true <- absolute_git_dir != common_dir do
      {:ok, Path.dirname(common_dir)}
    else
      false -> {:error, :not_a_linked_worktree}
      {:error, _reason} = error -> error
    end
  end

  defp current_worktree_metadata(source_repo, workspace) do
    source_repo = Path.expand(source_repo)
    workspace = Path.expand(workspace)

    case run_command("git", ["-C", source_repo, "worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> parse_worktree_metadata()
        |> Enum.find(fn metadata -> metadata.workspace == workspace end)
        |> case do
          nil -> {:error, :not_a_linked_worktree}
          metadata -> {:ok, metadata}
        end

      {:error, _reason} ->
        {:error, :worktree_metadata_unavailable}
    end
  end

  defp parse_worktree_metadata(output) when is_binary(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.reduce([], fn block, acc ->
      case parse_worktree_metadata_block(block) do
        %{workspace: workspace} = metadata when is_binary(workspace) -> [metadata | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_worktree_metadata_block(block) when is_binary(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, metadata ->
      cond do
        String.starts_with?(line, "worktree ") ->
          Map.put(metadata, :workspace, Path.expand(String.trim_leading(line, "worktree ")))

        String.starts_with?(line, "branch refs/heads/") ->
          Map.put(metadata, :branch, String.trim_leading(line, "branch refs/heads/"))

        true ->
          metadata
      end
    end)
  end

  defp git_absolute_path(args, workspace) when is_binary(workspace) do
    case run_command("git", ["-C", workspace | args]) do
      {:ok, output} ->
        case output |> String.trim() |> normalize_git_path(workspace) do
          nil -> {:error, :path_unavailable}
          path -> {:ok, path}
        end

      {:error, _reason} ->
        {:error, :path_unavailable}
    end
  end

  defp normalize_absolute_path(""), do: nil

  defp normalize_absolute_path(path) when is_binary(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> nil
    end
  end

  defp normalize_git_path("", _workspace), do: nil

  defp normalize_git_path(path, workspace) when is_binary(path) and is_binary(workspace) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.expand(path, workspace)
    end
  end

  defp normalize_optional_path(nil), do: nil
  defp normalize_optional_path(path) when is_binary(path), do: normalize_absolute_path(path)

  defp remove_worktree(source_repo, workspace) do
    case run_command("git", ["-C", source_repo, "worktree", "remove", "--force", workspace]) do
      {:ok, _output} ->
        Mix.shell().info("Removed Git worktree #{workspace}")
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to remove Git worktree #{workspace}: exit #{status}#{format_output(trimmed_output)}")
        :error
    end
  end

  defp prune_worktrees(source_repo) do
    case run_command("git", ["-C", source_repo, "worktree", "prune"]) do
      {:ok, _output} ->
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)
        Mix.shell().error("Failed to prune Git worktrees in #{source_repo}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp current_branch(nil) do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp current_repo_slug(nil), do: nil

  defp current_repo_slug(workspace) when is_binary(workspace) do
    case run_command("git", ["-C", workspace, "remote", "get-url", "origin"]) do
      {:ok, output} ->
        output
        |> String.trim()
        |> parse_github_repo_slug()

      {:error, _reason} ->
        nil
    end
  end

  defp parse_github_repo_slug("git@github.com:" <> rest), do: normalize_github_repo_slug(rest)
  defp parse_github_repo_slug("ssh://git@github.com/" <> rest), do: normalize_github_repo_slug(rest)
  defp parse_github_repo_slug("https://github.com/" <> rest), do: normalize_github_repo_slug(rest)
  defp parse_github_repo_slug("http://github.com/" <> rest), do: normalize_github_repo_slug(rest)
  defp parse_github_repo_slug(_remote_url), do: nil

  defp normalize_github_repo_slug(remote_path) when is_binary(remote_path) do
    case remote_path |> String.trim_leading("/") |> String.trim_trailing(".git") |> String.split("/", parts: 3) do
      [owner, repo] when owner != "" and repo != "" -> owner <> "/" <> repo
      _ -> nil
    end
  end

  defp restore_original_cwd({:ok, cwd}, source_repo) when is_binary(cwd) and is_binary(source_repo) do
    cond do
      File.dir?(cwd) -> File.cd!(cwd)
      File.dir?(source_repo) -> File.cd!(source_repo)
      true -> :ok
    end
  end

  defp restore_original_cwd(_original_cwd, source_repo) when is_binary(source_repo) do
    if File.dir?(source_repo), do: File.cd!(source_repo), else: :ok
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        try do
          case System.cmd(path, args, stderr_to_stdout: true) do
            {output, 0} -> {:ok, output}
            {output, status} -> {:error, {status, output}}
          end
        rescue
          error in ErlangError ->
            {:error, {error.original, ""}}
        end
    end
  end
end
