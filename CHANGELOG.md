# Unreleased

Console images now animate in place: `ui.image()` creates one display and
`.set(frame)` replaces its latest frame using the same ID. Added adaptive
refresh targeting 30 FPS, background decoding, delta image transport, and
bounded frame caches. HeliOS RGBA images encode directly in memory. Added
Python and simulator regressions for animation, image identity, and text output.

Scripts can import local helper modules and packages from the Files folder.
Refresh import discovery before each run so newly added files are available
without restarting, and retain the Files import path if a script changes its
working directory. Added regression coverage and a multi-file example.

# 2.0.0

Revamped the native iPhone workspace with separate Code, Console, Window, and
Files tabs. Added autosaved scripts with v1 migration and crash recovery, inline
input, ANSI console colors, bounded output, find and replace, automatic
indentation, error-line navigation, themes, text sizing, and a package screen.

Kept CPython 3.13, NumPy, SDL2, the app icon, the bundle identifier, existing
package folders, and the verified IPA-inside-ZIP download format. Added simulator
coverage for the full Swift interface and script persistence alongside expanded
Python regression tests.
