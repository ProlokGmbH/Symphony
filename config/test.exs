import Config

config :symphony_elixir, run_startup_preflight_on_boot: false
config :symphony_elixir, run_terminal_workspace_cleanup_on_start: false
config :symphony_elixir, run_initial_orchestrator_poll_on_start: false

if is_nil(System.get_env("LINEAR_ASSIGNEE")) do
  System.put_env("LINEAR_ASSIGNEE", "test-assignee@example.com")
end
