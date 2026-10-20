#!/usr/bin/env python3
"""Host-side smoke tests for PyPhone's Python runner and UI bridge.

Run this with the build Mac's Python 3.13 before compiling the iOS app.
The iOS-only NumPy binary is checked separately during packaging.
"""
import datetime
import math
import sys
import time
import traceback
from pathlib import Path

REAL_STDOUT = sys.stdout
REAL_STDERR = sys.stderr
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))


def main():
    assert math.isclose(math.sqrt(81), 9.0)
    assert datetime.date(2026, 1, 2).year == 2026

    import ui

    ui._reset()
    called = []
    button = ui.button("test", lambda: called.append(True))
    ui._event(button.id, "tap", "")
    assert called == [True], "UI button callback did not run"

    import runner

    runner.run_code(
        "import math, datetime, json\n"
        "print('runtime-ok', math.sqrt(81), datetime.date(2026, 1, 2).year)\n"
    )
    deadline = time.monotonic() + 5
    while runner._run_tid[0] != 0 and time.monotonic() < deadline:
        time.sleep(0.02)
    assert runner._run_tid[0] == 0, "Python runner did not finish"
    output = runner.take_output()
    assert "runtime-ok 9.0 2026" in output, (
        "Python runner output was unexpected: " + repr(output)
    )


try:
    main()
except BaseException:
    traceback.print_exc(file=REAL_STDERR)
    raise SystemExit(1)
else:
    REAL_STDOUT.write("PyPhone Python runner/UI smoke tests passed.\n")
