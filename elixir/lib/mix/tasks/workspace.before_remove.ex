defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Close open GitHub PRs for the current branch before workspace removal"

  @moduledoc """
  Closes open pull requests for the current Git branch.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
      mix workspace.before_remove --workspace /path/to/worktree --source-repo /path/to/source-repo
  """

  @default_repo "openai/symphony"

  @impl Mix.Task
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
        repo = opts[:repo] || current_repo_slug(workspace) || @default_repo
        branch = opts[:branch] || current_branch(workspace)

        maybe_close_open_pull_requests(repo, branch)
        maybe_remove_current_worktree(workspace, source_repo)
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

  defp maybe_remove_current_worktree(workspace_override, source_repo_override) do
    with {:ok, workspace} <- current_workspace(workspace_override),
         {:ok, source_repo} <- current_worktree_source_repo(workspace, source_repo_override) do
      original_cwd = File.cwd()

      case File.cd(source_repo) do
        :ok ->
          try do
            remove_worktree(source_repo, workspace)
            prune_worktrees(source_repo)
          after
            restore_original_cwd(original_cwd, source_repo)
          end

        {:error, reason} ->
          Mix.shell().error("Failed to change directory to #{source_repo} before removing current Git worktree: #{inspect(reason)}")
      end
    end

    :ok
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

  defp git_absolute_path(args, _workspace) do
    case run_command("git", args) do
      {:ok, output} ->
        case output |> String.trim() |> normalize_absolute_path() do
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

  defp normalize_optional_path(nil), do: nil
  defp normalize_optional_path(path) when is_binary(path), do: Path.expand(path)

  defp remove_worktree(source_repo, workspace) do
    case run_command("git", ["-C", source_repo, "worktree", "remove", "--force", workspace]) do
      {:ok, _output} ->
        Mix.shell().info("Removed Git worktree #{workspace}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to remove Git worktree #{workspace}: exit #{status}#{format_output(trimmed_output)}")
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

  defp current_branch(workspace) when is_binary(workspace) do
    case run_command("git", ["-C", workspace, "branch", "--show-current"]) do
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
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
