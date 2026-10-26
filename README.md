# PyPhone 2

A native Python workspace for iPhone, built around CPython 3.13 and the existing
NumPy-enabled iOS runtime. Version **2.0.0** keeps the app's bundle identifier,
Files folders, and installed packages.

## What's new

- Four workspaces: **Code**, **Console**, **Window**, and **Files**.
- Autosaved `.py` scripts, a searchable file list, rename, duplicate, import,
  export, and starter examples. Your v1 editor draft migrates to its own file.
- Full-height editor with line numbers, syntax colors, find and replace,
  automatic indentation, undo/redo, and adjustable text size.
- Inline `input()` with Send and keyboard return. Repeated identical prompts
  use unique request IDs; empty answers are supported.
- Full-height console with Colorama foreground/background colors, copy, clear,
  Latest, scrollback, run duration, and links to error lines when the source
  still matches the executed script.
- A package installation screen that leaves your code untouched, plus a list
  of installed distributions. Pure-Python wheels are supported; install their
  dependencies separately. Native packages still need an iOS app build.
- Dark, light, and system appearance. Pending and displayed output are bounded
  so print loops do not accumulate unlimited console text.

## Install from an iPhone

1. Open the latest successful **PyPhone iOS Build** in GitHub Actions.
2. Download the **pyphone** artifact and extract it in Files.
3. Extract `PyPhone_ipa.zip` to get `PyPhone.ipa`.
4. Use your existing SideStore or LiveContainer installation workflow.

The IPA is unsigned. It uses the same `com.example.pyphone` bundle ID; install
over your existing app using the same signing setup to retain its data. Deleting
the installed app removes its sandbox, so export scripts first if reinstalling.

Scripts are in **On My iPhone → PyPhone → Files**. The existing Packages,
Installed, and InstalledPackages folders continue to work. Relative Python file
paths still use the Files folder. If another app edits a script while PyPhone has
unsaved changes, PyPhone saves its draft as a separate recovered file.

## Validation

`python scripts/test_contracts.py`, `python scripts/test_runtime.py`, and
`python scripts/test_regressions.py` check the bridge, callbacks, repeated input,
errors, output limits, and package metadata. Host runtime tests need NumPy.

GitHub Actions also compiles all Swift screens in an iOS simulator test project
using a stub interpreter, checks script migration/recovery and scrolling, and
captures an editor screenshot. The device build uses the real Python/SDL2
frameworks and verifies the IPA resources, version, and both ZIP archives.

## Device checks for 2.0

- Upgrade without deleting v1; check that the old draft and packages remain.
- Run Guess the number; submit several answers, an empty answer, and quit.
- Run a long script, scroll to its final line, find text, and undo an edit.
- Run `for n in range(10000): print(n)`, scroll up, then tap Latest.
- Run `print(missing)` and use Go to line; fix it and rerun.
- Create two scripts, edit both, relaunch, and check their saved contents.
- Try Build a window and tap its buttons in Window.
- Install a pure-Python package from Files → Python packages and import it.

Stop requests a Python `KeyboardInterrupt`. A native extension or blocking
system operation may not stop until it returns control to Python.
