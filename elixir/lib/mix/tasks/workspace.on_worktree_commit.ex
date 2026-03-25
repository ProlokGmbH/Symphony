defmodule Mix.Tasks.Workspace.OnWorktreeCommit do
  use Mix.Task

  @shortdoc "Merge a committed worktree HEAD into the active branch of the source worktree"

  @moduledoc """
  Merges a committed worktree HEAD into the currently checked out branch of the
  source worktree without any push or pull.

  This task is intended for use from the `on_worktree_commit` workspace hook.

  Usage:

      mix workspace.on_worktree_commit --new-head <sha>
      mix workspace.on_worktree_commit --source-repo /path/to/source-repo --new-head <sha>
      mix workspace.on_worktree_commit --workspace /path/to/worktree --branch feature/example --old-head <old> --new-head <sha>
  """

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          source_repo: :string,
          workspace: :string,
          branch: :string,
          old_head: :string,
          new_head: :string
        ],
        aliases: [h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      if invalid != [] do
        Mix.raise("Invalid option(s): #{inspect(invalid)}")
      end

      source_repo = resolve_source_repo(opts[:source_repo])
      workspace = normalize_optional_path(opts[:workspace])
      branch = opts[:branch]
      old_head = opts[:old_head]
      new_head = required_sha!(opts[:new_head], "--new-head")

      ensure_commit_available!(source_repo, new_head)

      current_branch = current_branch!(source_repo)
      current_head = current_head!(source_repo)

      if commit_ancestor?(source_repo, new_head, current_head) do
        Mix.shell().info(
          "Source branch #{current_branch} already contains #{new_head}" <>
            format_optional_context(workspace, branch, old_head)
        )
      else
        merge_commit!(source_repo, current_branch, new_head, workspace, branch, old_head)
      end
    end
  end

  defp resolve_source_repo(nil) do
    case current_repo_root() do
      nil -> Mix.raise("Missing --source-repo and current repo is unavailable")
      repo -> repo
    end
  end

  defp resolve_source_repo(path) when is_binary(path) do
    case normalize_optional_path(path) do
      nil -> Mix.raise("Expected --source-repo to be an absolute path")
      repo -> repo
    end
  end

  defp required_sha!(value, _flag) when is_binary(value) and value != "", do: value
  defp required_sha!(_value, flag), do: Mix.raise("Missing required #{flag}")

  defp current_repo_root do
    case run_command("git", ["rev-parse", "--show-toplevel"]) do
      {:ok, output} ->
        output
        |> String.trim()
        |> normalize_optional_path()

      {:error, _reason} ->
        nil
    end
  end

  defp current_branch!(source_repo) when is_binary(source_repo) do
    case run_command("git", ["-C", source_repo, "branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> Mix.raise("Source repo #{source_repo} is in detached HEAD state")
          branch -> branch
        end

      {:error, {status, output}} ->
        Mix.raise("Failed to read current branch for #{source_repo}: exit #{status}#{format_output(output)}")
    end
  end

  defp current_head!(source_repo) when is_binary(source_repo) do
    case run_command("git", ["-C", source_repo, "rev-parse", "HEAD"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> Mix.raise("Source repo #{source_repo} has no readable HEAD")
          head -> head
        end

      {:error, {status, output}} ->
        Mix.raise("Failed to read current HEAD for #{source_repo}: exit #{status}#{format_output(output)}")
    end
  end

  defp ensure_commit_available!(source_repo, sha) when is_binary(source_repo) and is_binary(sha) do
    case run_command("git", ["-C", source_repo, "cat-file", "-e", "#{sha}^{commit}"]) do
      {:ok, _output} ->
        :ok

      {:error, {status, output}} ->
        Mix.raise("Commit #{sha} is unavailable in #{source_repo}: exit #{status}#{format_output(output)}")
    end
  end

  defp commit_ancestor?(source_repo, left, right)
       when is_binary(source_repo) and is_binary(left) and is_binary(right) do
    case run_command("git", ["-C", source_repo, "merge-base", "--is-ancestor", left, right]) do
      {:ok, _output} ->
        true

      {:error, {1, _output}} ->
        false

      {:error, {status, output}} ->
        Mix.raise("Failed to compare commits in #{source_repo}: exit #{status}#{format_output(output)}")
    end
  end

  defp merge_commit!(source_repo, current_branch, new_head, workspace, branch, old_head)
       when is_binary(source_repo) and is_binary(current_branch) and is_binary(new_head) do
    context = format_optional_context(workspace, branch, old_head)

    case run_command("git", ["-C", source_repo, "merge", "--no-edit", new_head]) do
      {:ok, _output} ->
        Mix.shell().info("Merged #{new_head} into #{current_branch}#{context}")

      {:error, {status, output}} ->
        maybe_abort_merge(source_repo)

        Mix.raise("Failed to merge #{new_head} into #{current_branch} in #{source_repo}: exit #{status}#{format_output(output)}#{context}")
    end
  end

  defp maybe_abort_merge(source_repo) when is_binary(source_repo) do
    case run_command("git", ["-C", source_repo, "rev-parse", "-q", "--verify", "MERGE_HEAD"]) do
      {:ok, _output} ->
        case run_command("git", ["-C", source_repo, "merge", "--abort"]) do
          {:ok, _output} ->
            :ok

          {:error, {_status, _output}} ->
            :ok
        end

      {:error, {_status, _output}} ->
        :ok
    end
  end

  defp normalize_optional_path(nil), do: nil

  defp normalize_optional_path(path) when is_binary(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> nil
    end
  end

  defp format_optional_context(workspace, branch, old_head) do
    [
      workspace && " workspace=#{workspace}",
      branch && " worktree_branch=#{branch}",
      old_head && " previous_head=#{old_head}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp format_output(output) when is_binary(output) do
    case String.trim(output) do
      "" -> ""
      trimmed_output -> " output=#{inspect(trimmed_output)}"
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
