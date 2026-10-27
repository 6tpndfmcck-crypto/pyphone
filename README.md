# PyPhone 2.0

A native Python workspace for iPhone, powered by **CPython 3.13**. Write, run, and organize Python scripts directly on iOS without a computer.

## Features at a glance

- **Code:** Full-height script editor with line numbers, syntax highlighting, find and replace, automatic indentation, undo/redo, and adjustable text size.
- **Console:** Run Python, view output and errors, respond to `input()` prompts, copy or clear output, and jump back to the latest output.
- **Window:** A dedicated workspace for supported Python-driven interfaces and interactive examples.
- **Files:** Create and manage autosaved `.py` scripts; search, rename, duplicate, import, and export files.
- **Packages:** Install supported pure-Python packages without replacing your editor content; inspect installed distributions.
- **Appearance:** Dark, light, and system themes.

## What's new in version 2

PyPhone 2.0 introduces four dedicated workspaces, a redesigned full-height editor and console, autosaved scripts, file migration from version 1, an integrated package installation screen, and improved interactive input handling.

The editor supports syntax colors, line numbers, scrolling, search and replace, auto-indentation, and undo/redo. Console output supports Colorama foreground/background colors, a **Latest** control, scrollback, run duration, and links back to error lines when the executed code still matches the current file. Output buffers are bounded so very large print loops do not accumulate unlimited text.

## Getting started

1. Open **Code** and create or select a Python script.
2. Enter code, for example:

   ```python
   name = input("What is your name? ")
   print("Hello,", name)
   ```
3. Run the script.
4. Switch to **Console** to see output and answer prompts using **Send** or the keyboard return key.
5. Return to **Code** to revise your script. Scripts are autosaved.

Repeated `input()` prompts are handled as separate requests, even when their prompt text is identical. Empty answers are supported.

### Example: NumPy

The app's Python runtime includes NumPy:

```python
import numpy as np

numbers = np.array([5, 15, 25, 35, 45])
print(numbers[numbers > 20])
print(np.sum(numbers > 20))
```

### Example: a simple game

```python
import random

answer = random.randint(1, 10)
guess = int(input("Guess a number from 1 to 10: "))

if guess == answer:
    print("Correct!")
else:
    print("It was", answer)
```

## Code workspace

The editor is intended for real multiline Python scripts, not just single commands. It includes line numbers, Python syntax highlighting, adjustable font size, find/replace, automatic indentation, and undo/redo. Files are saved automatically.

For syntax or runtime errors, use the console's available error-line navigation to return to the relevant code. Navigation is conditional on the current source matching the version that was run.

## Console workspace

The console displays standard output, runtime errors, elapsed run time, and interactive prompts.

- Type and send responses to Python `input()` calls.
- Scroll through prior output; use **Latest** to return to the newest entries.
- Copy console text or clear the display.
- Use **Stop** to request a Python `KeyboardInterrupt`.
- Colorama text colors are supported.

**Important:** Stopping code is cooperative. A blocking native call or extension may not stop until control returns to Python. Very large output is bounded for performance; the console is not an unlimited log archive.

## Window workspace

**Window** is the home for supported graphical interfaces created through PyPhone's available UI facilities. The bundled **Build a window** starter example is a useful first test: run it, switch to Window, and try the buttons. The UI support available in PyPhone is not the same as a full desktop Python GUI environment.

## Files workspace

Manage multiple scripts without losing the current editor draft:

- Create and open `.py` scripts.
- Search scripts by filename.
- Rename or duplicate scripts.
- Import and export files using iOS Files.
- Explore included starter examples.
- Access the Python packages installation screen.

Script storage is available in **On My iPhone → PyPhone → Files**. Relative file paths in executed Python code use that Files directory. Existing **Packages**, **Installed**, and **InstalledPackages** directories remain supported.

When upgrading from v1, the existing editor draft migrates to a file. If an external edit conflicts with an unsaved draft, PyPhone preserves a recovered draft as a separate file rather than silently overwriting it.

**Back up scripts before deleting the app.** Deleting an iOS app can remove its sandbox data.

### Using multiple Python files

Scripts can import helpers saved in the same Files folder. For example, save `helper.py`:

```python
def greet(name):
    return f"Hello, {name}!"
```

Then run another script containing:

```python
from helper import greet

print(greet("PyPhone"))
```

Package folders with an `__init__.py` are also supported when placed in Files through iOS Files. Newly added modules are available on the next run. Bundled modules and installed packages take precedence over local files with the same name.

Python caches imported modules between runs. After editing an already imported helper, use `import helper; import importlib; importlib.reload(helper)` before accessing its updated functions, or restart the app.

## Python runtime and packages

### Animating images in the Console

`ui.image(source)` inserts one image beside ordinary Console text. Call
`.set(frame)` on the returned object to update that display in place. Frames do
not add Console lines, move the image, or require saving PNG files.

HeliOS images work directly, including RGBA transparency, `.paste()`, and
`.resize()`. The package is distributed as **helios-image** on PyPI and imported
as `helios`; install it through Python packages if it is not already installed.
For example, put `1coin.PNG` in Files and run:

```python
import helios
import ui
import time

coin = helios.open("1coin.PNG").resize((80, 80))
screen = ui.image(helios.new("RGBA", (300, 400), (0, 0, 0, 0)))

for y in range(0, 321, 5):
    frame = helios.new("RGBA", (300, 400), (0, 0, 0, 0))
    frame.paste(coin, (110, y))
    screen.set(frame)
    time.sleep(0.03)
```

Refresh targets approximately 30 FPS while images change and slows to the usual
200 ms interval when idle. Slower devices, large images, and Python computation
can lower the frame rate; intermediate frames are dropped in favor of the
latest frame. Image decoding runs off the interface thread and unchanged frames
are reused. Normal text, `input()`, and errors still share the Console.

Images retain their Console position until output is cleared or trimmed. Frame
payloads are limited to 8 MB per source image, with at most 16 recent image
snapshots and 32 MiB of encoded data retained per cache. Older images may lose
their displayed pixels when evicted. Displayed images are downsampled to at most
1024 pixels on their longest side; the original Python image is unchanged.

PyPhone uses **CPython 3.13** with an iOS-compatible runtime and NumPy. Standard Python features such as variables, functions, loops, exceptions, lists, and imports work subject to iOS restrictions.

Use **Files → Python packages** to install a supported Python distribution. The package screen does not overwrite the source code currently in the editor.

### Package installation limitations

- The in-app installer is intended for **pure-Python wheels**.
- Install missing package dependencies separately when required.
- Packages containing compiled native extensions generally require compatible iOS binaries bundled through an app build; ordinary desktop wheels cannot simply be loaded.
- Installing a Python wrapper does not automatically supply a missing native library (for example, SDL2).
- iOS does not provide normal desktop-style subprocess behavior, so commands relying on `subprocess`, `os.system`, or external executables may not work.
- Not every standard-library or third-party feature available on a desktop is supported on iOS.

If a package installs but fails to import, check its dependencies and whether it requires compiled code or a native system library.

## Installing PyPhone on an iPhone

1. Open the repository's **Actions** tab.
2. Select the latest successful **PyPhone iOS Build** workflow run.
3. Download the **pyphone** artifact and extract it in the iOS Files app.
4. Extract `PyPhone_ipa.zip` to obtain `PyPhone.ipa`.
5. Install using your existing **SideStore** or **LiveContainer** setup.

The build produces an **unsigned IPA**, not an App Store download. Signing/installing it is a separate step. Version 2 retains the bundle ID `com.example.pyphone`. Installing over the existing app with a compatible signing setup is intended to preserve data; avoid deleting your old installation until your scripts and packages are backed up.

## Troubleshooting

### Nothing appears after a prompt
Open Console and check whether Python is waiting for an `input()` response. Submit the value using Send or return.

### `ModuleNotFoundError`
Verify the name you imported and whether the package is installed. If it requires compiled extensions or native libraries, the in-app installer may not be sufficient.

### `SyntaxError`
Check the indicated line for missing punctuation, mismatched brackets, or indentation. Use error-line navigation when available.

### `ValueError` after `int(input(...))`
The entered text may not be a valid integer. Validate or catch the conversion error.

### Long output is hard to follow
Scroll the console or tap **Latest** to jump to new output. Extremely long output may be truncated intentionally.

### A script will not stop immediately
Stop requests a `KeyboardInterrupt`; blocking native operations can delay delivery.

### Files disappeared after reinstalling
Check **On My iPhone → PyPhone → Files** and your exported backups. Deleting an app can delete its sandbox, so always export important work before removing it.

## Development and validation

The repository includes checks for core runtime and app contracts:

```bash
python scripts/test_contracts.py
python scripts/test_runtime.py
python scripts/test_regressions.py
```

Host runtime tests require NumPy; install `helios-image==0.3.0` to also run the real HeliOS animation regression. GitHub Actions installs both dependencies, compiles Swift screens in a simulator test project with a stub interpreter, tests migration/recovery, scrolling, and image animation, and captures an editor screenshot. The device build uses the actual Python/SDL2 frameworks and checks IPA resources, version, and packaged ZIP archives.

### Recommended on-device smoke tests

1. Upgrade without deleting v1 and verify that your old draft and packages remain.
2. Run a script with several `input()` calls, including an empty answer.
3. Create two scripts; close and reopen the app to confirm autosave.
4. Scroll through a long source file, search text, and undo an edit.
5. Print thousands of lines and use **Latest**.
6. Run `print(missing)` and use the error link to fix the line.
7. Run **Build a window** and test its buttons in Window.
8. Install a small pure-Python package and import it.

## Project notes

PyPhone is built for writing and running Python on an iPhone. It is **not** a full desktop Python environment: package compatibility, native libraries, process creation, filesystem access, and GUI toolkits remain constrained by iOS.

Version: **2.0.0**.
