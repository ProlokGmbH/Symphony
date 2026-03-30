import Config

config :symphony_elixir, run_startup_preflight_on_boot: false

if is_nil(System.get_env("LINEAR_ASSIGNEE")) do
  System.put_env("LINEAR_ASSIGNEE", "test-assignee@example.com")
end
