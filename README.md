# PyPhone 2.0

A native Python workspace for iPhone. Write, run, and organize Python scripts on iOS with **CPython 3.13**, **NumPy**, an autosaving editor, and a Console that supports text, input, and animated images.

**Requires iOS 16 or later.** The project builds an unsigned IPA for installation through your own signing or app-container setup. Editing and running local scripts work offline once the app and any required packages are installed.

## Contents

- [What the app includes](#what-the-app-includes)
- [Install PyPhone](#install-pyphone)
- [Run your first script](#run-your-first-script)
- [Code editor](#code-editor)
- [Running code and using the Console](#running-code-and-using-the-console)
- [Files, autosave, and backups](#files-autosave-and-backups)
- [Multiple files and local imports](#multiple-files-and-local-imports)
- [Python UI controls](#python-ui-controls)
- [Images and animation](#images-and-animation)
- [Python runtime and packages](#python-runtime-and-packages)
- [Settings](#settings)
- [More examples](#more-examples)
- [Troubleshooting](#troubleshooting)
- [Development and testing](#development-and-testing)
- [Compatibility and limits](#compatibility-and-limits)

## What the app includes

PyPhone has three tabs:

| Area | What you can do |
| --- | --- |
| **Code** | Edit scripts with line numbers, syntax colors, find and replace, indentation, undo/redo, and keyboard suggestions. |
| **Console** | Read output and errors, answer `input()` prompts, view images and animation, select text, and copy or clear output. |
| **Files** | Create, open, search, import, and delete scripts; open the Python packages screen. |

Interactive Python labels, text fields, and buttons appear in **PROGRAM WINDOW**, below the Code editor. Images appear inline in Console. There is no separate Window tab in the current interface.

The header shows Python's status and the **Run/Stop** control. The slider icon opens settings. The layout supports portrait and landscape orientations. The interface uses a black-and-white appearance with dark, light, and system themes; syntax colors, ANSI output colors, and image colors remain available.

See [CHANGELOG.md](CHANGELOG.md) for changes to the app.

## Install PyPhone

1. Open [GitHub Actions](https://github.com/6tpndfmcck-crypto/pyphone/actions/workflows/build.yml).
2. Choose a successful **PyPhone iOS Build** run for the revision you want.
3. Download the **pyphone** artifact. GitHub may require you to sign in to download artifacts.
4. Extract the downloaded artifact ZIP in iOS Files. It contains `PyPhone_ipa.zip`, `PyPhone_SHA256.txt`, and `xcodebuild.log`.
5. Extract `PyPhone_ipa.zip` to obtain `PyPhone.ipa`.
6. Sign or install the IPA using your existing **SideStore**, **LiveContainer**, or other compatible setup, following that tool's instructions.

The IPA is unsigned. The repository does not provide an App Store installation or a signing service. Artifacts are configured to expire after 14 days; choose a newer successful run or run the workflow again if a download has expired.

The bundle ID is `com.example.pyphone`, and the app version is **2.0.0**. Installing an update over an existing installation with a compatible signing setup is intended to preserve app data. **Export important scripts and copy any assets or package folders before deleting or replacing the app.** Deleting an iOS app can delete its sandbox data.

## Run your first script

1. Open PyPhone and wait for the Python and NumPy readiness check to finish.
2. Open **Code**. An empty workspace initially creates a welcome script named `hello.py`.
3. Enter this code:

   ```python
   name = input("What is your name? ")
   print("Hello,", name + "!")
   ```

4. Tap **Run**. PyPhone saves the script and switches to Console.
5. Type your answer in the input field and tap the arrow button labeled **Send input**, or press return.
6. Return to **Code** to edit and run again.

New scripts created through **Files → New script** or the Code actions menu start blank. You do not need to press a separate Save button; scripts autosave.

## Code editor

The editor supports multiline Python scripts and scrolling through long files. It includes:

- Line numbers that stay aligned with wrapped source lines.
- Syntax highlighting for Python keywords, strings, comments, numbers, and common built-ins.
- **Find and replace**, opened with the magnifying-glass button.
- A keyboard accessory bar with **Undo**, **Redo**, four-space indentation, suggestions, punctuation, and **Done** to dismiss the keyboard.
- Suggestions based on Python vocabulary, known module member lists, and names in the current document. These are editing aids rather than a full language server or type checker.
- Automatic continuation of leading whitespace, with an extra four spaces after a block-opening colon. Disable this in Settings if you prefer manual indentation.
- Adjustable text size, plus the filename, saved/saving status, and source line count.

The **ellipsis menu beside the filename** contains:

| Action | Result |
| --- | --- |
| **New script** | Create and open a blank script. |
| **Import from Files** | Copy a selected text/Python file into the workspace. |
| **Rename** | Rename the current saved script. |
| **Duplicate** | Create a separate copy of the current script. |
| **Install Python package** | Open the package installer without replacing your code. |
| **Export .py file** | Export the current source through iOS Files. |

For an error with an available source line, Console offers **Go to line N**. The link is shown only while the current filename and source still match the script that ran.

## Running code and using the Console

### Execution model

Each Run executes the current script in fresh top-level globals, with `__name__` set to `"__main__"`. A new Run clears the previous Console output, image displays, and Python UI controls.

The embedded interpreter stays alive between runs, so imported modules and their state can remain cached. PyPhone runs editor source as `<code>` and does not define `__file__` for that source. Use paths relative to the Files directory, or `Path.cwd()`, when locating your script's resources.

Only one script or button callback runs at a time. Run and button taps cannot start overlapping executions.

### Output and input

- `print()` and standard error appear in Console alongside images.
- `input()` opens an inline answer field and switches to Console when needed. Repeated identical prompts are separate requests, and empty answers are supported.
- Running or waiting status is shown in the interface, and elapsed duration is shown after execution finishes.
- Scroll up to read earlier output. Scroll back to the bottom to resume following new output. There is no dedicated Latest button in the current interface.
- Select text normally, or use **Console ellipsis → Copy output** to copy plain text. ANSI escapes are removed and images are represented by `[image]` in copied output.
- **Console ellipsis → Clear console** clears the displayed output and image positions. It does not stop running Python.

The Console renders common ANSI foreground/background colors and bold/reset styling. You can print ANSI escape sequences directly or install `colorama` and use its constants. It is an output view, not a system shell or a full terminal emulator with desktop cursor control.

Output buffers are bounded. Very large print loops retain recent text and may display an older-output-trimmed notice; Console is not an unlimited log archive. Save important results to a file if you need to keep them.

### Stopping and errors

Tap **Stop** to request a Python `KeyboardInterrupt`. Python loops and waiting input can normally be interrupted, but a blocking native call or extension may delay delivery until it returns control to Python.

Errors include the exception type, a short explanation, available source/line information, details, and a suggested next step. Name errors may include a spelling suggestion. Use **Go to line N** when it is available, or return to Code and inspect the reported source.

## Files, autosave, and backups

### Managing scripts

The Files tab lists scripts by most recent modification time. It supports filename search, opening scripts, creating new scripts, importing, and deletion with confirmation. Rename, duplicate, and export are available in the **Code** actions menu after opening a script.

Imports must be **UTF-8 text** and at most **2 MiB**. Imported files are copied into the workspace as `.py` scripts; editing the copy does not edit the original file from the import picker. Names are normalized, and existing names receive a numeric suffix instead of being overwritten. Renaming to an existing filename produces an error.

The app's script list shows supported `.py` files at the top level of its Files directory. Use the **iOS Files app** to manage subfolders, images, data files, and package directories.

### Storage layout

In iOS Files, open **On My iPhone → PyPhone**:

```text
PyPhone/
├── Files/                  # Scripts, images, local packages, and other data
│   ├── hello.py
│   ├── helper.py
│   └── 1coin.PNG
├── Packages/               # Incoming .whl files for installation
├── Installed/              # Archived successfully processed wheels
└── InstalledPackages/      # Extracted package folders used for imports
```

Python starts each Run with **Files** as its working directory. For example:

```python
from pathlib import Path

print("Working directory:", Path.cwd())
Path("notes.txt").write_text("Saved from PyPhone\n", encoding="utf-8")
print(Path("notes.txt").read_text(encoding="utf-8"))
```

This creates `notes.txt` beside your scripts. For a subfolder, use a relative path such as `assets/coin.png`. Copy assets into the app's Files directory through iOS Files; the script import picker is for source files.

### Autosave and recovery

Edits retain a pending recovery draft immediately, then save to disk after about 0.4 seconds of inactivity. PyPhone also saves before running code, switching or creating files, and leaving the active app.

Script writes are atomic. If a save fails, the draft remains available and file actions that would discard it are blocked. If an external iOS Files edit conflicts with a pending draft, PyPhone saves a separate recovered copy instead of silently overwriting the external version. Pending drafts can also be recovered after an interrupted session.

On the first upgrade from v1, the old editor draft is copied into a uniquely named script; the legacy draft is retained in app preferences. Returning to the app reloads the active script from Files after saving any local draft.

Export scripts through the Code menu and copy associated images, data, and package folders through iOS Files for backup. Exporting a `.py` file does not bundle its resources or installed dependencies.

## Multiple files and local imports

Save reusable helpers beside the main script. Use filenames that are valid Python module names, such as `helper.py`, without spaces or hyphens.

Save this as `helper.py`:

```python
def greet(name):
    return f"Hello, {name}!"
```

Then run a second script:

```python
from helper import greet

print(greet("PyPhone"))
```

Package directories with an `__init__.py` also work when placed in Files through iOS Files. New modules are discoverable on the next Run. Bundled modules and installed packages take precedence over local files with the same name.

Already imported modules remain cached between runs. After editing a helper, restart the app or reload it explicitly:

```python
import importlib
import helper

importlib.reload(helper)
print(helper.greet("again"))
```

If you previously used `from helper import greet`, import that name again after reloading so it refers to the updated function.

## Python UI controls

PyPhone includes a small `ui` module for native controls and Console images. Import it with `import ui`; it is separate from third-party desktop GUI libraries.

| API | Behavior |
| --- | --- |
| `ui.label(text="")` | Create a text label below the Code editor. |
| `ui.entry(placeholder="", text="")` | Create a text field with an optional initial value. |
| `ui.button(text, on_click)` | Create a button whose callback takes no arguments. |
| `ui.image(source)` | Insert an image file or HeliOS image into Console. |
| `ui.clear()` | Remove the current interactive controls; already emitted Console images remain subject to the image cache limits. |
| `widget.set(value)` | Set a control's text, or replace an image's displayed frame. |
| `widget.get()` | Read the widget's text. For images, this returns a description/path rather than pixel data. |

### Example: a small interactive interface

```python
import ui

name = ui.entry("Your name")
greeting = ui.label("Ready when you are.")

def say_hello():
    greeting.set("Hello, " + (name.get() or "world") + "!")
    print("Greeting updated")

ui.button("Say hello", say_hello)
print("Open Code to use the controls below the editor.")
```

Let the script finish, then return to Code and tap the button. Controls remain available after the initial execution; you do not need a loop to keep them alive. Buttons are disabled while a script or another callback is running. Callbacks can print, update controls or images, and request `input()` through Console.

`ui.clear()` and **Clear console** have different purposes: the former clears Python controls, while the latter clears Console text and image positions. A new Run resets both.

## Images and animation

### Displaying an image

Put a supported image file in the app's Files directory and run:

```python
import ui

picture = ui.image("picture.png")
print("An image and ordinary text share this Console.")
```

`ui.image()` also accepts HeliOS image objects directly. Install **`helios-image`** through Python packages if needed; its Python import name is **`helios`**. The package named just `helios` on PyPI is a different project.

```python
import helios
import ui

canvas = helios.new("RGBA", (300, 200), (0, 0, 0, 0))
picture = ui.image(canvas)
```

RGBA transparency is preserved. HeliOS operations such as `.paste()`, `.resize()`, and other image edits continue to operate on the Python image; PyPhone encodes the result directly in memory for display.

### Updating one display in place

Create the display once, then call `.set(frame)` to update it. The widget keeps its ID and original position among the Console text. Updates do not append another image marker or a new Console line.

The following example expects `1coin.PNG` in Files:

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

To try this without an external image, replace the `coin = ...` line with:

```python
coin = helios.new("RGBA", (80, 80), (255, 200, 0, 255))
```

That animates a colored square. Individual PNG frame files are not required. Keep the canvas dimensions consistent for a stable animation area.

### Refresh behavior and limits

- Refresh targets approximately **30 FPS** while images change and returns to an approximately **200 ms** polling interval when idle.
- Intermediate updates coalesce to the latest frame instead of accumulating a frame queue. Identical frames reuse the existing display data.
- Image decoding runs off the main interface thread. Image-only updates preserve text, image identity, selection, and scroll position.
- Actual frame rate depends on the iPhone, image size, PNG encoding, and the script's other work. This is not a guaranteed 30 FPS game engine.
- Each source image is limited to **8 MiB**. Image caches retain at most **16 recent snapshots** and **32 MiB of encoded data per cache**; old images can lose their displayed pixels when evicted.
- Display images are downsampled to at most **1024 pixels on the longest side**. The original Python image is unchanged.

Console clearing, a new Run, or text trimming can remove an image's position. After clearing Console, call `ui.image(...)` again to insert a new display; `.set()` updates an existing position rather than recreating cleared output.

## Python runtime and packages

### Included runtime

PyPhone embeds CPython 3.13 and an iOS-compatible standard library. The build pins these bundled packages in [requirements.txt](requirements.txt):

| Distribution | Pinned version | Purpose |
| --- | --- | --- |
| NumPy | `2.5.2.post1` | iOS-compatible numerical arrays and operations. |
| pip | `25.2` | Bundled Python packaging tooling. |
| certifi | `2025.1.31` | Certificate authorities used for HTTPS package downloads. |

HeliOS and Colorama are optional installations, not bundled requirements. Import names can differ from distribution names: install `helios-image`, then `import helios`.

### Installing from PyPI

1. Open **Files → Python packages**, or **Code ellipsis → Install Python package**.
2. Enter one distribution name, optionally pinned to a version, such as `helios-image==0.3.0` or `colorama`.
3. Tap **Install package**. Progress and errors appear in Console; your editor content is preserved.
4. Return to your script and import the package using its Python module name.

The packages screen also shows discovered installed distributions and their versions. Network access is required for a PyPI download.

As a convenience, PyPhone recognizes a standalone editor command such as:

```text
pip install helios-image==0.3.0
```

This line must be run on its own. It is handled by PyPhone's package installer, not by a system shell, and does not implement the complete pip command-line interface. Use the packages screen to install without replacing your script.

### Installing a wheel through iOS Files

1. Obtain a compatible pure-Python `.whl` file.
2. Copy it into **On My iPhone → PyPhone → Packages**.
3. Restart PyPhone so interpreter startup processes the incoming wheels.
4. Check Console for installation messages, then import the package.

Successfully processed wheels move to **Installed** and their contents are extracted under **InstalledPackages**. Failed wheels remain in Packages for inspection or removal. A wheel already installed at the same target is skipped and archived.

### Package compatibility and version management

- The installer selects compatible **pure-Python `none-any` wheels**. Source distributions and ordinary desktop native-extension wheels are unsupported.
- It installs **one wheel at a time**. Install missing dependencies separately; there is no automatic dependency resolver.
- Installed wheels are limited to **50 MiB of expanded content**.
- Extras, multiple-package commands, arbitrary pip options, requirements-file commands, and source builds are outside this installer interface.
- Reinstalling the same target does not replace its existing files. Installing a different version can leave multiple version folders; the installer does not remove older versions or guarantee that the newest one is selected.
- Imported modules remain cached. Restart the app after changing installed package files or versions. There is no in-app uninstall screen; manage extracted package folders through iOS Files with the app closed.
- Compiled extensions require compatible iOS binaries bundled through an app build. Installing a Python wrapper does not supply a missing native library.

SDL2 is embedded as an iOS framework by the build workflow. PySDL2 library lookup is configured, but desktop window/event-loop behavior is not guaranteed. See [SDL2-iOS.md](SDL2-iOS.md) for the native framework build and integration limits.

## Settings

Open the **slider icon** in the header:

| Setting | Options |
| --- | --- |
| Appearance | Dark, Light, or System. |
| Text size | 11–24 points for editor and Console text. |
| Automatic indentation | Enable or disable the editor's newline indentation aid. |
| Python status | Read the interpreter/NumPy readiness result. |
| Version | Read the installed app's version. |

## More examples

### NumPy arrays

```python
import numpy as np

numbers = np.array([5, 15, 25, 35, 45])
print("Above 20:", numbers[numbers > 20])
print("Count:", np.sum(numbers > 20))
print("Average:", np.mean(numbers))
```

### Input validation

```python
answer = input("Enter a whole number: ")
try:
    number = int(answer)
except ValueError:
    print("That was not a whole number.")
else:
    print("Double:", number * 2)
```

### Colored output without an extra package

```python
print("\x1b[32mGreen text\x1b[0m and normal text")
```

Additional starter source for greetings, a number game, native UI controls, and NumPy is in [sources/Examples.swift](sources/Examples.swift). There is no examples browser in the current app; copy an example into a new script to try it.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Run is unavailable at launch | Wait for Python and NumPy checks. Read the header/Settings status if startup reports a failure. |
| A script seems stuck after a prompt | Open Console and send an answer to `input()`, including an empty answer if appropriate. |
| Stop does not take effect immediately | A native operation may still be blocking. The interrupt is delivered when Python can handle it. |
| `ModuleNotFoundError` | Check the import name, local filename, installed distribution, and missing dependencies. For HeliOS, install `helios-image` and import `helios`. |
| An edited helper still has old behavior | Reload the module, re-import any copied names, or restart the app. |
| A relative file or image cannot be found | Put the resource in the app's Files directory and check its exact name and relative path. Editor source does not define `__file__`. |
| An image animation creates many copies | Create one `ui.image(...)` before the loop and call that widget's `.set(frame)` inside the loop. |
| An image vanished after clearing or long output | Its Console position or cached pixels may have been removed. Insert a new image display with `ui.image(...)`. |
| Animation is slow | Use a smaller canvas, reuse one display, leave a short sleep between updates, and reduce other work in the loop. |
| A package will not install | Check for a compatible pure-Python wheel and the expanded-size limit. Dependencies and native extensions require separate handling. |
| A wheel copied into Packages does nothing yet | Restart the app to process dropped wheels; failed files remain in Packages. |
| Import fails or source looks corrupted | The source import picker expects UTF-8 text up to 2 MiB. |
| Long output disappears | Console intentionally trims old output. Save results to a file when you need a persistent record. |
| A recovered script appears | PyPhone preserved a pending draft or conflicting external edit as a separate file. Compare the versions before removing either one. |
| Files disappeared after reinstalling | Check your iOS Files copies and exports. Deleting the app can remove its local data. |

For a reproducible problem, include the app/build version, iOS version, a small script, expected behavior, actual output/error, and relevant package versions when [opening an issue](https://github.com/6tpndfmcck-crypto/pyphone/issues).

## Development and testing

### Repository layout

| Path | Contents |
| --- | --- |
| [sources/](sources/) | SwiftUI interface, editor, Console renderer, persistence, and Objective-C Python bridge. |
| [app/runner.py](app/runner.py) | Python execution, input/output, diagnostics, package installation, and bridge state. |
| [app/ui.py](app/ui.py) | Python widget API and image snapshots. |
| [scripts/](scripts/) | Runtime staging, SDL2 build, host smoke tests, and regressions. |
| [tests/](tests/) | Swift simulator tests and a stub Python bridge. |
| [project.yml](project.yml) | XcodeGen definition for the device app. |
| [scrolling-tests.yml](scrolling-tests.yml) | XcodeGen definition for simulator UI/model checks. |
| [.github/workflows/](.github/workflows/) | Source checks, iOS IPA packaging, and SDL2 framework builds. |

### Host Python checks

With Python 3.13, from the repository root:

```bash
python3.13 -m venv .build-venv
source .build-venv/bin/activate
python -m pip install --only-binary=:all: "numpy==2.3.5" "helios-image==0.3.0"
python -m py_compile app/runner.py app/ui.py scripts/test_contracts.py scripts/test_runtime.py scripts/test_regressions.py
python scripts/test_contracts.py
python scripts/test_runtime.py
python scripts/test_regressions.py
```

Host NumPy `2.3.5` is used for these checks; the packaged iOS NumPy wheel is pinned separately. HeliOS enables the real RGBA/paste/resize animation regression. Tests cover bridge contracts, execution, prompts, callbacks, errors, bounded output, package installation, local imports, and image identity/deltas.

### Simulator checks

On a Mac with Xcode and XcodeGen installed:

```bash
xcodegen generate --spec scrolling-tests.yml
xcrun simctl list devices available
xcodebuild test -project ScrollingChecks.xcodeproj -scheme ScrollingChecks \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Replace `SIMULATOR_UDID` with an available iPhone simulator ID from the preceding command. This project compiles the Swift screens with a stub interpreter, so device-only Python and SDL2 frameworks are not required for these tests. It exercises persistence, migration/recovery, editor/Console scrolling, inline input, stable image updates, cache limits, and viewport preservation.

The **PyPhone source checks** workflow runs host and simulator validation and uploads available screenshots as **pyphone-v2-ui**.

### Device builds

The [PyPhone iOS Build workflow](.github/workflows/build.yml) is the complete reference for staging and building the app. It runs on pushes to `main` and can also be started manually from Actions.

A local device build needs more than `xcodegen generate`: stage the BeeWare **Python 3.13-b16** framework and standard library, prepare the iOS-target `app_packages`, build `SDL2.xcframework`, and generate the app icon assets first. The workflow records the exact download targets and preparation commands. See [scripts/install_python.sh](scripts/install_python.sh) for the post-build runtime installation and [SDL2-iOS.md](SDL2-iOS.md) for SDL2 preparation.

The build creates an unsigned IPA and checks the packaged Python resources, NumPy, SDL2, native framework layout, IPA structure, ZIP integrity, and checksums. Signing and installation are separate from these checks.

### Useful on-device checks

1. Create and reopen two scripts; verify autosave and external Files edits.
2. Run repeated `input()` prompts, including an empty answer.
3. Search and replace text, undo an edit, and scroll to the end of a long script.
4. Run a local helper import and read/write a relative data file.
5. Run the native button example and use it after the initial script finishes.
6. Run the falling-image animation; check one display, transparency, scrollback, and Stop.
7. Run a script with an error and use its available source-line link.
8. Install a small pure-Python wheel and import it.
9. Back up your scripts and resources before testing an upgrade or reinstall.

## Compatibility and limits

PyPhone runs Python inside an iOS app sandbox. Standard language features and compatible packages work within that environment, with these practical limits:

- The Console is not a system shell, and subprocesses, external executables, and desktop-style process management may be unavailable.
- Desktop native wheels, arbitrary GUI toolkits, and desktop window/event-loop assumptions do not automatically work on iOS. PyPhone's `ui` controls and Console images are its supported built-in display paths.
- Each Run gets fresh script globals, while imports can retain state in the shared interpreter.
- The in-app script list is for top-level `.py` files; use iOS Files for folders and other resources.
- Console text and image caches are bounded, so exported files are the place for long-term results.
- Stop is cooperative, and animation frame rate depends on device performance and workload.

For release history, see [CHANGELOG.md](CHANGELOG.md). For native SDL2 details, see [SDL2-iOS.md](SDL2-iOS.md).
