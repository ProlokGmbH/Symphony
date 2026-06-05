defmodule SymphonyElixir.RuntimeInstancesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeInstances

  test "active_count returns at least one for the real process table" do
    assert RuntimeInstances.active_count() >= 1
  end

  test "active_count counts Symphony escript commands from ps output" do
    output = """
    /home/dev/project/bin/symphony -B -- -extra /home/dev/project/bin/symphony
    /tmp/other/bin/symphony --port 4001
    /bin/bash -c rg bin/symphony
    rg bin/symphony
    /home/dev/.local/bin/symphony-PRO-475
    """

    runner = fn "ps", ["-axo", "command="], [stderr_to_stdout: true] -> {output, 0} end

    assert RuntimeInstances.active_count(runner) == 2
  end

  test "active_count falls back to one when ps cannot be read" do
    failed_runner = fn "ps", ["-axo", "command="], [stderr_to_stdout: true] -> {"boom", 1} end
    raising_runner = fn "ps", ["-axo", "command="], [stderr_to_stdout: true] -> raise "boom" end
    throwing_runner = fn "ps", ["-axo", "command="], [stderr_to_stdout: true] -> throw(:boom) end

    assert RuntimeInstances.active_count(failed_runner) == 1
    assert RuntimeInstances.active_count(raising_runner) == 1
    assert RuntimeInstances.active_count(throwing_runner) == 1
  end

  test "count_from_ps_output counts only bin/symphony main commands and returns at least one" do
    output = """

    bin/symphony --yolo
    '/home/dev/project/bin/symphony' --port 4001
    /home/dev/project/bin/symphony-helper
    /bin/bash -c ps -axo command= | rg bin/symphony
    rg bin/symphony
    """

    assert RuntimeInstances.count_from_ps_output(output) == 2
    assert RuntimeInstances.count_from_ps_output("") == 1
    assert RuntimeInstances.count_commands([""]) == 1
  end
end
