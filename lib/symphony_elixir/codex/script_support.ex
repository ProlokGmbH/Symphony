defmodule SymphonyElixir.Codex.ScriptSupport do
  @moduledoc false

  alias SymphonyElixir.{Config, EnvFile, PromptBuilder, Tracker, Workflow}

  @spec workspace_root(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def workspace_root(workflow_path, env_files_dir)
      when is_binary(workflow_path) and is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir) do
      {:ok, Config.settings!().workspace.root}
    end
  end

  @spec manual_prompt(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def manual_prompt(workflow_path, interactive_workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(interactive_workflow_path) and
             is_binary(issue_identifier) and is_binary(env_files_dir) do
    with {:ok, %{prompt: prompt}} <-
           manual_prompt_context(
             workflow_path,
             interactive_workflow_path,
             issue_identifier,
             env_files_dir
           ) do
      {:ok, prompt}
    end
  end

  @spec manual_prompt_context(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{prompt: String.t(), workflow_step: String.t() | nil}} | {:error, term()}
  def manual_prompt_context(workflow_path, interactive_workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(interactive_workflow_path) and
             is_binary(issue_identifier) and is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir),
         {:ok, prompt_template} <- load_prompt_template(interactive_workflow_path),
         {:ok, issue} <- Tracker.fetch_issue_by_identifier(issue_identifier) do
      {:ok,
       %{
         prompt: prompt_for_issue(issue, prompt_template),
         workflow_step: issue.state
       }}
    end
  end

  @spec prompt_for_issue(map(), String.t()) :: String.t()
  defp prompt_for_issue(issue, prompt_template) when is_map(issue) and is_binary(prompt_template) do
    PromptBuilder.build_prompt(
      issue,
      prompt_template: prompt_template,
      session_mode: :manual
    )
  end

  defp load_prompt_template(workflow_path) when is_binary(workflow_path) do
    with {:ok, %{prompt_template: prompt_template}} <- Workflow.load(workflow_path) do
      {:ok, prompt_template}
    end
  end

  defp load_runtime_context(workflow_path, env_files_dir) do
    with :ok <- EnvFile.load(EnvFile.config_dir(env_files_dir)) do
      with :ok <- Workflow.set_workflow_file_path(workflow_path),
           {:ok, _apps} <- Application.ensure_all_started(:req) do
        :ok
      end
    end
  end
end
