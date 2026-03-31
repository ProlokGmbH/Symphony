defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityPubSub
  @pubsub_child_id Phoenix.PubSub.Supervisor

  setup do
    ensure_pubsub_running()
    :ok
  end

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    on_exit(fn ->
      ensure_pubsub_running()
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, @pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end

  defp ensure_pubsub_running do
    if Process.whereis(SymphonyElixir.PubSub) == nil do
      case Supervisor.restart_child(SymphonyElixir.Supervisor, @pubsub_child_id) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end
end
