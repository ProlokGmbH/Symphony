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
  """

  @default_repo "openai/symphony"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        repo = opts[:repo] || @default_repo
        branch = opts[:branch] || current_branch()

        maybe_close_open_pull_requests(repo, branch)
        maybe_remove_current_worktree()
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

  defp maybe_remove_current_worktree do
    with {:ok, workspace} <- current_workspace(),
         {:ok, source_repo} <- current_worktree_source_repo(workspace) do
      case File.cd(source_repo) do
        :ok ->
          remove_worktree(source_repo, workspace)
          prune_worktrees(source_repo)

        {:error, reason} ->
          Mix.shell().error("Failed to change directory to #{source_repo} before removing current Git worktree: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp current_workspace do
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

  defp current_worktree_source_repo(workspace) do
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

  defp current_branch do
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
