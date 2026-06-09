ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

symphony_runtime_env_snapshot = SymphonyElixir.TestSupport.scrub_symphony_runtime_env()

ExUnit.after_suite(fn _result ->
  SymphonyElixir.TestSupport.restore_env_snapshot(symphony_runtime_env_snapshot)
end)
