import Config

if is_nil(System.get_env("LINEAR_ASSIGNEE")) do
  System.put_env("LINEAR_ASSIGNEE", "test-assignee@example.com")
end
