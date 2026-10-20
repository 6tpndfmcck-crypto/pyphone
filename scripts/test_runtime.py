#!/usr/bin/env python3
"""Host-side smoke tests for PyPhone's Python runner and UI bridge.

Run with the build Mac's Python 3.13 before compiling the iOS app. The
iOS-only NumPy binary is checked separately during packaging and at app startup.
"""
import datetime
import json
import math
import sys
import threading
import time
import traceback
from pathlib import Path

REAL_STDOUT = sys.stdout
REAL_STDERR = sys.stderr
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))


def wait_for_runner(runner, timeout=5):
    deadline = time.monotonic() + timeout
    while runner._running[0] and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not runner._running[0], "Python runner did not finish before timeout"


def main():
    assert math.isclose(math.sqrt(81), 9.0)
    assert datetime.date(2026, 1, 2).year == 2026

    import ui

    ui._reset()
    called = []
    button = ui.button("test", lambda: called.append(True))
    ui._event(button.id, "tap", "")
    assert called == [True], "UI button callback did not run"

    entry = ui.entry("Name", "before")
    ui._event(entry.id, "change", "after")
    assert entry.get() == "after", "UI entry changes were not reflected in Python"
    label = ui.label("before")
    label.set("after")
    assert label.get() == "after", "UI label setter did not update its value"

    import runner

    # Verify the runner starts, executes code, and prevents overlapping runs.
    runner.run_code(
        "import math, datetime, json, time\n"
        "print('runtime-start')\n"
        "time.sleep(0.3)\n"
        "print('runtime-ok', math.sqrt(81), datetime.date(2026, 1, 2).year)\n"
    )
    runner.run_code("print('should-not-run')")
    wait_for_runner(runner)
    output = runner.take_output()
    assert "runtime-start" in output, "Python code did not start"
    assert "runtime-ok 9.0 2026" in output, (
        "Python runner output was unexpected: " + repr(output)
    )
    assert "Already running" in output, "Concurrent Run was not rejected"
    assert "should-not-run" not in output, "Overlapping code unexpectedly executed"

    # Verify input() prompts and receives an answer through the bridge.
    runner.run_code("name = input('Name? ')\nprint('hello', name)\n")
    deadline = time.monotonic() + 5
    while runner._prompt[0] is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert runner._prompt[0] == "Name? ", "input() did not publish its prompt"
    runner.input_reply("Alice")
    wait_for_runner(runner)
    output = runner.take_output()
    assert "Name? Alice" in output and "hello Alice" in output, (
        "input() result was unexpected: " + repr(output)
    )

    # Verify that user syntax errors are printed to the terminal rather than
    # silently lost by the embedded runner.
    runner.run_code("if True print('broken')\n")
    wait_for_runner(runner)
    output = runner.take_output()
    assert "SyntaxError" in output, "Python syntax error was not shown in output"

    # A UI callback can outlive the original script. Verify a new Run is
    # rejected while a button callback is still active.
    ui._reset()
    slow_button = ui.button("slow", lambda: time.sleep(0.3))
    event = json.dumps({"id": slow_button.id, "kind": "tap", "value": ""})
    callback = threading.Thread(target=runner.send_event, args=(event,))
    callback.start()
    deadline = time.monotonic() + 5
    while runner._cb_tid[0] == 0 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert runner._cb_tid[0] != 0, "UI callback did not start"
    callback_state = json.loads(runner.get_state())
    assert callback_state["running"] and callback_state["tid"] != 0, (
        "Active UI callback was not represented as running"
    )
    runner.run_code("print('callback-overlap-should-not-run')")
    callback.join(timeout=5)
    assert not callback.is_alive(), "UI callback did not finish"
    output = runner.take_output()
    assert "Already running" in output, "Run was not blocked during a UI callback"
    assert "callback-overlap-should-not-run" not in output, (
        "Code ran concurrently with a UI callback"
    )


try:
    main()
except BaseException:
    traceback.print_exc(file=REAL_STDERR)
    raise SystemExit(1)
else:
    REAL_STDOUT.write("PyPhone Python runner/UI smoke tests passed.\n")
