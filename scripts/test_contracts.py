#!/usr/bin/env python3
"""Check that the Swift, Python, and build files agree on their interfaces."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


runner_py = read("app/runner.py")
ui_py = read("app/ui.py")
runner_swift = read("sources/Runner.swift")
content_swift = read("sources/ContentView.swift")
bridge_h = read("sources/PythonBridge.h")
bridge_m = read("sources/PythonBridge.m")
project = read("project.yml")
codemagic = read("codemagic.yaml")
requirements = read("requirements.txt")

# Swift can only invoke functions that the embedded Python runner actually has.
swift_calls = set(re.findall(r'PythonBridge\\.call\\("([A-Za-z_]\\w*)"', runner_swift))
python_functions = set(re.findall(r"^def\\s+([A-Za-z_]\\w*)\\s*\\(", runner_py, re.MULTILINE))
require(swift_calls <= python_functions,
        "Swift calls Python functions missing from runner.py: " +
        ", ".join(sorted(swift_calls - python_functions)))
require({"start", "call", "stopThread"} <= set(
    re.findall(r"\\+ \\(?:nullable NSString \\*|NSString \\*|void \\)(\\w+)", bridge_h)
), "PythonBridge.h is missing a public method used by Swift")
require(set(re.findall(r"\\+ \\(?:nullable NSString \\*|NSString \\*|void \\)(\\w+)", bridge_m)) >=
        {"start", "call", "stopThread"},
        "PythonBridge.m does not implement the declared bridge methods")

# The Python JSON payload must exactly provide the fields decoded by Swift.
state_block = runner_py.split("return json.dumps({", 1)[1].split("\\n    })", 1)[0]
python_state_keys = set(re.findall(r'"([a-z_]+)"\\s*:', state_block))
py_state_struct = re.search(r"struct PyState:.*?\\{(.*?)\\n\\}", runner_swift, re.S)
widget_struct = re.search(r"struct Widget:.*?\\{(.*?)\\n\\}", runner_swift, re.S)
require(py_state_struct is not None and widget_struct is not None,
        "Swift Widget/PyState models are missing")
swift_state_keys = set(re.findall(r"^\\s*let (\\w+):", py_state_struct.group(1), re.MULTILINE))
swift_widget_keys = set(re.findall(r"^\\s*(?:let|var) (\\w+):", widget_struct.group(1), re.MULTILINE))
require(python_state_keys == swift_state_keys,
        f"Python state keys {sorted(python_state_keys)} do not match Swift PyState fields {sorted(swift_state_keys)}")

widget_block = ui_py.split("def _state():", 1)[1].split("\\ndef _event(", 1)[0]
python_widget_keys = set(re.findall(r'"([a-z_]+)"\\s*:', widget_block))
require(python_widget_keys == swift_widget_keys,
        f"Python widget keys {sorted(python_widget_keys)} do not match Swift Widget fields {sorted(swift_widget_keys)}")

# Starter code must only import API functions exported from ui.py, and Swift
# must have a rendering path for each widget kind produced by that module.
starter_import = re.search(r"from ui import ([^\\n]+)", content_swift)
require(starter_import is not None, "Starter example has no ui imports")
starter_api = {item.strip() for item in starter_import.group(1).split(",")}
ui_functions = set(re.findall(r"^def ([A-Za-z_]\\w*)\\s*\\(", ui_py, re.MULTILINE))
require(starter_api <= ui_functions,
        "Starter example imports missing ui functions: " +
        ", ".join(sorted(starter_api - ui_functions)))
python_widget_kinds = set(re.findall(r'Widget\\("([a-z_]+)"', ui_py))
require({"label", "button", "entry"} <= python_widget_kinds,
        "ui.py is missing one or more standard widget types")
require('case "button":' in content_swift and 'case "entry":' in content_swift and "default:" in content_swift,
        "Swift WidgetView must render button, entry, and label/default widgets")

# Verify the build and resource layout agree with the runtime's paths.
require("- sources" in project and "path: app" in project and "path: app_packages" in project,
        "XcodeGen project must include sources, app, and app_packages")
require("Python.xcframework" in project and "scripts/install_python.sh" in project,
        "XcodeGen project must link Python.xcframework and run the Python installer")
require("Python.xcframework" in codemagic and "requirements.txt" in codemagic and
        "python-stdlib/python3.13" in codemagic and "app_packages" in codemagic,
        "Codemagic staging does not provide all runtime resources")
require("--python-version 3.13" in codemagic and "--abi cp313" in codemagic and
        "--platform ios_13_0_arm64_iphoneos" in codemagic,
        "Codemagic NumPy wheel target does not match the Python/iOS runtime")
require(requirements.strip() == "numpy==2.5.2.post1",
        "iOS NumPy dependency must remain pinned to the tested BeeWare wheel")

print("PyPhone cross-file interface and build-resource checks passed.")
