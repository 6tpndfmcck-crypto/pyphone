#!/usr/bin/env python3
"""Regression tests for input, callbacks, diagnostics, and package installation."""
import builtins
from contextlib import contextmanager
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))
CONSOLE = sys.stderr
DOCUMENTS = tempfile.TemporaryDirectory(prefix="pyphone-regressions-")
os.environ["PYPHONE_DOCUMENTS"] = DOCUMENTS.name
import runner
import ui


def wait_until(predicate):
    deadline = time.monotonic() + 5
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for Python")
        time.sleep(0.01)


@contextmanager
def local_scripts():
    """Model the embedded runtime: no implicit cwd entry on sys.path."""
    previous_directory = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="pyphone-local-") as documents:
        folder = Path(documents).resolve() / "Files"
        folder.mkdir()
        paths = [path for path in sys.path if path not in ("", str(folder))]
        with mock.patch.dict(os.environ, {"PYPHONE_DOCUMENTS": documents}), \
                mock.patch.object(sys, "path", paths):
            try:
                yield folder
            finally:
                wait_until(lambda: not runner._running[0] and not runner._callback_running[0])
                os.chdir(previous_directory)
                sys.path_importer_cache.pop(str(folder), None)
                for name in list(sys.modules):
                    if name.startswith("_pyphone_local_"):
                        del sys.modules[name]


class Regressions(unittest.TestCase):
    def setUp(self):
        wait_until(lambda: not runner._running[0] and not runner._cb_tid[0])
        runner.take_output()
        ui.clear()

    def test_import_sibling_script_after_working_directory_changes(self):
        with local_scripts() as folder:
            (folder / "_pyphone_local_helper.py").write_text("VALUE = 42\n", encoding="utf-8")
            (folder / "nested").mkdir()
            runner.run_code("import os\nos.chdir('nested')\nfrom _pyphone_local_helper import VALUE\nprint('nested:', VALUE)")
            wait_until(lambda: not runner._running[0])
            self.assertIn("nested: 42", runner.take_output())
            for _ in range(2):
                runner.run_code("from _pyphone_local_helper import VALUE\nprint('helper:', VALUE)")
                wait_until(lambda: not runner._running[0])
                self.assertIn("helper: 42", runner.take_output())
                self.assertEqual(Path.cwd(), folder)
            self.assertEqual(sys.path.count(str(folder)), 1)
            self.assertLess(sys.path.index(str(ROOT / "app")), sys.path.index(str(folder)))

    def test_import_local_package_with_relative_import(self):
        with local_scripts() as folder:
            package = folder / "_pyphone_local_package"
            package.mkdir()
            (package / "__init__.py").write_text("from .helper import VALUE\n", encoding="utf-8")
            (package / "helper.py").write_text("VALUE = 'package ready'\n", encoding="utf-8")
            runner.run_code("from _pyphone_local_package import VALUE\nprint(VALUE)")
            wait_until(lambda: not runner._running[0])
            self.assertIn("package ready", runner.take_output())

    def test_import_new_script_invalidates_directory_cache(self):
        with local_scripts() as folder:
            runner.run_code("try:\n    import _pyphone_local_later\nexcept ModuleNotFoundError:\n    print('not yet')")
            wait_until(lambda: not runner._running[0])
            self.assertIn("not yet", runner.take_output())
            timestamp = folder.stat()
            (folder / "_pyphone_local_later.py").write_text("VALUE = 'new script ready'\n", encoding="utf-8")
            # FileFinder caches directory contents by mtime. Simulate a Files
            # edit within the same filesystem timestamp tick.
            os.utime(folder, ns=(timestamp.st_atime_ns, timestamp.st_mtime_ns))
            runner.run_code("from _pyphone_local_later import VALUE\nprint(VALUE)")
            wait_until(lambda: not runner._running[0])
            self.assertIn("new script ready", runner.take_output())

    def test_error_without_colorama(self):
        with mock.patch.dict(sys.modules, {"colorama": None}):
            runner._show_friendly_error(ValueError("bad value"))
        output = runner.take_output()
        self.assertIn("WHAT HAPPENED", output)
        self.assertIn("HOW TO FIX IT", output)

    def test_flood_output_is_bounded_and_keeps_latest_text(self):
        stream = runner._Out()
        self.assertEqual(stream.write("x" * 500_000), 500_000)
        for _ in range(30_000):
            stream.write("line\n")
        stream.write("latest\n")
        self.assertLessEqual(stream.size, stream.MAX_PENDING)
        self.assertTrue(stream.trimmed)
        self.assertTrue("".join(stream.buf).endswith("latest\n"))

    def test_error_line_resets_for_next_run(self):
        runner.run_code("x = 1\nprint(missing)\n")
        wait_until(lambda: not runner._running[0])
        self.assertEqual(json.loads(runner.get_state())["error_line"], 2)
        runner.run_code("print('fixed')")
        wait_until(lambda: not runner._running[0])
        self.assertIsNone(json.loads(runner.get_state())["error_line"])

    def test_many_identical_inputs_and_empty_answers(self):
        runner.run_code("answers = [input('Answer: ') for _ in range(20)]\nprint(repr(answers))")
        previous = -1
        try:
            for index in range(20):
                wait_until(lambda: runner._prompt[0] is not None and runner._prompt_id[0] != previous)
                previous = runner._prompt_id[0]
                runner.input_reply(json.dumps({"prompt_id": previous, "text": "" if index % 2 else str(index)}))
            wait_until(lambda: not runner._running[0])
            self.assertIn("'18', ''", runner.take_output())
        finally:
            # Unblock a worker if an assertion fails before all inputs complete.
            for _ in range(20):
                if not runner._running[0]:
                    break
                if runner._prompt[0] is not None:
                    runner.input_reply(json.dumps({"prompt_id": runner._prompt_id[0], "text": ""}))
                time.sleep(0.02)

    def test_package_list_uses_metadata_without_importing_packages(self):
        class Distribution:
            metadata = {"Name": "Test_Package"}
            version = "1.2"
        with mock.patch("importlib.metadata.distributions", return_value=[Distribution(), Distribution()]):
            self.assertEqual(json.loads(runner.list_packages()), [{"name": "Test_Package", "version": "1.2"}])

    def test_runtime_error_shows_source_and_real_suggestion(self):
        runner.run_code("score = 10\nprint(socre)\n")
        wait_until(lambda: not runner._running[0])
        output = runner.take_output()
        self.assertIn("print(socre)", output)
        self.assertIn("Did you mean 'score'", output)
        self.assertNotIn("Did you mean 'socre'", output)

    def test_multiline_code_is_not_a_pip_command(self):
        with mock.patch.object(runner.urllib.request, "urlopen") as network:
            self.assertFalse(runner._pip_install_command("pip install demo\nprint('hello')"))
            network.assert_not_called()

    def test_consecutive_identical_prompts_have_distinct_ids(self):
        runner.run_code("a = input('Answer?')\nb = input('Answer?')\nprint(a, b)")
        try:
            wait_until(lambda: runner._prompt[0] is not None)
            first = json.loads(runner.get_state())
            self.assertIn("prompt_id", first)
            runner.input_reply(json.dumps({"prompt_id": first["prompt_id"], "text": "first"}))
            wait_until(lambda: json.loads(runner.get_state())["prompt_id"] != first["prompt_id"])
            second = json.loads(runner.get_state())
            self.assertEqual(second["prompt"], "Answer?")
            runner.input_reply(json.dumps({"prompt_id": first["prompt_id"], "text": "stale"}))
            self.assertFalse(runner._got.is_set(), "Old reply answered the new prompt")
            runner.input_reply(json.dumps({"prompt_id": second["prompt_id"], "text": "second"}))
            wait_until(lambda: not runner._running[0])
            self.assertIn("first second", runner.take_output())
        finally:
            # Also clean up when this regression is run against the old runner.
            for _ in range(2):
                if runner._prompt[0] is not None:
                    state = json.loads(runner.get_state())
                    reply = json.dumps({"prompt_id": state["prompt_id"], "text": ""}) if "prompt_id" in state else ""
                    runner.input_reply(reply)
                time.sleep(0.03)

    def test_callback_does_not_block_bridge(self):
        entered, release, returned = threading.Event(), threading.Event(), threading.Event()
        def callback():
            entered.set()
            release.wait(5)
        button = ui.button("Wait", callback)
        def invoke():
            runner.send_event(json.dumps({"id": button.id, "kind": "tap"}))
            returned.set()
        caller = threading.Thread(target=invoke)
        caller.start()
        try:
            self.assertTrue(entered.wait(2))
            self.assertTrue(returned.wait(0.5), "Callback occupies the serial bridge queue")
            state = json.loads(runner.get_state())
            self.assertTrue(state["running"])
            self.assertNotEqual(state["tid"], 0)
        finally:
            release.set()
            caller.join(5)
            wait_until(lambda: not runner._cb_tid[0])

    def test_old_widget_event_cannot_hit_new_widget(self):
        calls = []
        old = ui.button("Old", lambda: None)
        ui.clear()
        new = ui.button("New", lambda: calls.append(True))
        ui._event(old.id, "tap", "")
        self.assertEqual(calls, [])
        self.assertNotEqual(old.id, new.id)

    def test_callback_input_and_overlapping_tap(self):
        calls = []
        def callback():
            calls.append(input("From button?"))
        button = ui.button("Input", callback)
        event = json.dumps({"id": button.id, "kind": "tap"})
        runner.send_event(event)
        try:
            wait_until(lambda: runner._prompt[0] is not None)
            state = json.loads(runner.get_state())
            self.assertEqual(state["prompt"], "From button?")
            self.assertTrue(state["running"])
            runner.send_event(event)
            runner.run_code("print('must not run')")
            runner.input_reply(json.dumps({"prompt_id": state["prompt_id"], "text": "answer"}))
            wait_until(lambda: not runner._callback_running[0])
            self.assertEqual(calls, ["answer"])
            output = runner.take_output()
            self.assertIn("Already running", output)
            self.assertNotIn("must not run", output)
        finally:
            if runner._prompt[0] is not None:
                runner.input_reply(json.dumps({"prompt_id": runner._prompt_id[0], "text": ""}))
            wait_until(lambda: not runner._callback_running[0])

    def test_reinstall_with_existing_archive_is_importable(self):
        incoming, archived, installed = runner._package_folders()
        name = "archive_probe-1.0-py3-none-any.whl"
        (archived / name).write_bytes(b"old archive")
        with zipfile.ZipFile(incoming / name, "w") as wheel:
            wheel.writestr("archive_probe.py", "VALUE = 42\n")
            wheel.writestr("archive_probe-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\n")
        runner._process_dropped_packages()
        self.assertEqual(importlib.import_module("archive_probe").VALUE, 42)

    def test_oversized_wheel_rejected_before_decompression(self):
        incoming, _, installed = runner._package_folders()
        path = incoming / "large-1.0-py3-none-any.whl"
        info = zipfile.ZipInfo("large.py")
        info.file_size = 51 * 1024 * 1024
        with mock.patch.object(runner.zipfile, "ZipFile") as archive:
            opened = archive.return_value.__enter__.return_value
            opened.infolist.return_value = [info]
            opened.testzip.return_value = None
            with self.assertRaisesRegex(ValueError, "50 MB"):
                runner._install_wheel(path, installed)
            opened.testzip.assert_not_called()


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=CONSOLE, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Regressions))
    os.chdir(ROOT)
    DOCUMENTS.cleanup()
    sys.exit(not result.wasSuccessful())

