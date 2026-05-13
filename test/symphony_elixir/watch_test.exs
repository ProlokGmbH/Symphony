defmodule SymphonyElixir.Codex.WatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Watch

  test "main prints compact interesting session output from the observability API" do
    test_pid = self()

    req_fun = fn opts ->
      send(test_pid, {:requested_url, Keyword.fetch!(opts, :url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "running" => %{"session_id" => "thread-1-turn-1"},
           "recent_events" => [
             %{
               "at" => "2026-05-12T19:59:58Z",
               "event" => "session_started",
               "message" => ""
             },
             %{
               "at" => "2026-05-12T19:59:59Z",
               "event" => "notification",
               "message" => "turn started (turn-1)"
             },
             %{
               "at" => "2026-05-12T20:00:00Z",
               "event" => "notification",
               "message" => "agent message streaming: Plan"
             },
             %{
               "at" => "2026-05-12T20:00:00Z",
               "event" => "notification",
               "message" => "agent message streaming:  anf"
             },
             %{
               "at" => "2026-05-12T20:00:01Z",
               "event" => "notification",
               "message" => "agent message streaming: asse."
             },
             %{
               "at" => "2026-05-12T20:00:02Z",
               "event" => "notification",
               "message" => "item completed: agent message (msg_123)"
             },
             %{
               "at" => "2026-05-12T20:00:03Z",
               "event" => "notification",
               "message" => "item started: command execution (call_123, inprogress)"
             },
             %{
               "at" => "2026-05-12T20:00:04Z",
               "event" => "notification",
               "message" => "git status --short"
             },
             %{
               "at" => "2026-05-12T20:00:05Z",
               "event" => "notification",
               "message" => "command completed (exit 0)"
             },
             %{
               "at" => "2026-05-12T20:00:06Z",
               "event" => "notification",
               "message" => "rate limits updated: primary 1% / 300m; secondary 5% / 10080m"
             }
           ]
         }
       }}
    end

    output_fun = fn line -> send(test_pid, {:output, line}) end
    write_fun = fn text -> send(test_pid, {:write, text}) end

    assert :ok =
             Watch.main(["--url", "http://127.0.0.1:4567", "--once", "PRO-265"],
               output_fun: output_fun,
               write_fun: write_fun,
               req_fun: req_fun
             )

    assert_received {:requested_url, "http://127.0.0.1:4567/api/v1/PRO-265"}
    assert_received {:output, "sym-watch PRO-265 -> http://127.0.0.1:4567"}
    assert_received {:output, "== Codex session thread-1-turn-1 =="}
    assert_received {:write, "Plan"}
    assert_received {:write, " anf"}
    assert_received {:write, "asse."}
    assert_received {:write, "\n"}
    assert_received {:output, "git status --short"}
    assert_received {:output, "command completed (exit 0)"}
    refute_received {:output, "turn started (turn-1)"}
    refute_received {:output, "item started: command execution (call_123, inprogress)"}
  end

  test "main waits when no session is running" do
    test_pid = self()
    req_fun = fn _opts -> {:ok, %{status: 404, body: %{}}} end
    output_fun = fn line -> send(test_pid, {:output, line}) end

    assert :ok =
             Watch.main(["--url", "http://127.0.0.1:4567", "--once", "PRO-404"],
               output_fun: output_fun,
               req_fun: req_fun
             )

    assert_received {:output, "Warte auf Codex-Sitzung für PRO-404 ..."}
  end

  test "main waits when the observability API is not reachable" do
    test_pid = self()
    req_fun = fn _opts -> {:error, %RuntimeError{message: "connection refused"}} end
    output_fun = fn line -> send(test_pid, {:output, line}) end

    assert :ok =
             Watch.main(["--url", "http://127.0.0.1:4567", "--once", "PRO-265"],
               output_fun: output_fun,
               req_fun: req_fun
             )

    assert_received {:output, "Warte auf Symphony-Observability-API unter http://127.0.0.1:4567 (connection refused). Starte Symphony mit `./symphony` oder setze `--url`."}
  end

  test "main ignores retained events from an older session when a new session is running" do
    test_pid = self()

    req_fun = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "running" => %{"session_id" => "thread-new-turn"},
           "recent_events" => [
             %{
               "at" => "2026-05-12T19:59:58Z",
               "event" => "notification",
               "session_id" => "thread-old-turn",
               "message" => "agent message streaming: stale"
             },
             %{
               "at" => "2026-05-12T20:00:00Z",
               "event" => "notification",
               "session_id" => "thread-new-turn",
               "message" => "agent message streaming: fresh"
             }
           ]
         }
       }}
    end

    output_fun = fn line -> send(test_pid, {:output, line}) end
    write_fun = fn text -> send(test_pid, {:write, text}) end

    assert :ok =
             Watch.main(["--url", "http://127.0.0.1:4567", "--once", "PRO-265"],
               output_fun: output_fun,
               write_fun: write_fun,
               req_fun: req_fun
             )

    assert_received {:output, "== Codex session thread-new-turn =="}
    refute_received {:write, "stale"}
    assert_received {:write, "fresh"}
  end

  test "main keeps repeated streaming deltas when the API provides distinct event sequences" do
    test_pid = self()

    req_fun = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "running" => %{"session_id" => "thread-repeat-turn"},
           "recent_events" => [
             %{
               "at" => "2026-05-12T20:00:00Z",
               "event" => "notification",
               "sequence" => 1,
               "session_id" => "thread-repeat-turn",
               "message" => "agent message streaming: ha"
             },
             %{
               "at" => "2026-05-12T20:00:00Z",
               "event" => "notification",
               "sequence" => 2,
               "session_id" => "thread-repeat-turn",
               "message" => "agent message streaming: ha"
             }
           ]
         }
       }}
    end

    write_fun = fn text -> send(test_pid, {:write, text}) end

    assert :ok =
             Watch.main(["--url", "http://127.0.0.1:4567", "--once", "PRO-265"],
               write_fun: write_fun,
               req_fun: req_fun
             )

    assert_receive {:write, "ha"}
    assert_receive {:write, "ha"}
  end
end
