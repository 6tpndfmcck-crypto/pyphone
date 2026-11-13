# Native SDL2 and Pygame support in PyPhone

PyPhone runs Python inside an iOS app, so installing the pure-Python `PySDL2` wrapper is not enough: iOS also needs a native SDL2 framework compiled for iOS. This repository does not commit that compiled binary.

## Build SDL2 and prepare PyPhone

On a Mac with Xcode and its command-line tools installed, from the repository root run:

```sh
bash scripts/build_sdl2_xcframework.sh
```

The script checks out the pinned official SDL2 source release (`release-2.32.10`), builds its `xcFramework-iOS` scheme for iOS device and simulator, and copies `SDL2.xcframework` to the repository root. To use another SDL2 source tag, set `SDL2_TAG` when running the script.

After staging the BeeWare Python 3.15-b3 framework and the iOS packages as in
`.github/workflows/build.yml`, build Pygame with Xcode and CMake installed:

```sh
python3 scripts/build_pygame_ios.py
xcodegen generate
```

The Pygame builder pins Pygame 2.6.1 and SDL_image 2.8.8, SDL_ttf 2.24.0,
and SDL_mixer 2.8.1 to exact source commits. It compiles Pygame's native modules
with the target Python headers and SDK into `app_packages/pygame`. A small
source patch delegates PNG saving to SDL_image instead of a separate libpng.
SDL_ttf uses its pinned FreeType submodule; images use the Apple ImageIO/STB
backends, and mixer includes WAV, Ogg Vorbis, MP3, and FLAC support. Optional
external codecs (MIDI, MOD, Opus, WavPack, AVIF, WebP) are disabled.

The addons share `PygameDependencies.xcframework` so `mixer` and `mixer_music`
use the same native mixer state. Every extension and addon links the existing
`SDL2.framework`. `project.yml` embeds both frameworks, and
`scripts/install_python.sh` converts Pygame extensions to signed-layout iOS
frameworks with `.fwork`/`.origin` markers, using the same path as NumPy.

For a simulator build, stage simulator-compatible Python packages first, then
run `python3 scripts/build_pygame_ios.py --sdk iphonesimulator --archs arm64`
(or `--archs x86_64` on an Intel Mac). The builder replaces its Pygame package
and dependency XCFramework for the selected platform. Re-run the default
device command before building an IPA; never combine simulator Pygame with
device NumPy. Other installed packages are retained.

`PythonBridge.m` still sets `PYSDL2_DLL_PATH` before Python initializes so
PySDL2 can locate the existing SDL2 framework.

## Runtime integration

`_pyphone_pygame` is a built-in native bridge registered before CPython starts.
`app/pygame_ios.py` imports the genuine Pygame C extensions and wraps their
display/event/key/mouse functions. It dispatches those operations to the main
queue, releases the worker's GIL while waiting, and returns Python results or
exceptions to the caller. Pygame types, software drawing, transforms, and the
game loop remain on the script worker. `event.wait()` polls on the main queue
and sleeps on the worker so the UIKit run loop stays responsive.
`SysFont` uses the bundled FreeSans font and Pygame's normal style/fallback
handling instead of attempting to launch the desktop fontconfig subprocess.

SDL is initialized with `SDL_SetMainReady()` while SwiftUI keeps ownership of
UIApplication. SDL's nested iOS event pump is disabled. The native bridge
forwards lifecycle/orientation notifications explicitly while that pump is off,
then restores SDL's event pump and renderer hint after the game closes. It
attaches SDL's UIKit window to the editor's active window scene, adds a Stop
button, and restores the original key window on teardown. Positive game sizes
use fullscreen SCALED mode with aspect-preserving letterboxing and SDL's
logical input coordinates. Metal presents the software surface; user OpenGL
contexts are unsupported. The runner cleans up games in `finally` after normal
completion, errors, and KeyboardInterrupt, including UI callbacks.

## Validation

Run `python scripts/test_pygame.py` with host Pygame 2.6.1 installed. It uses
real C extensions with SDL's dummy video/audio drivers and a serial test UI
dispatcher to check pixels, drawing, fonts, PNG round trips, audio, events,
timed waits, repeated runs, exceptions, interruption, and editor restoration.
It does not emulate UIKit or prove on-screen iOS presentation.

The IPA workflow cross-compiles Pygame, verifies the embedded dependency
framework, default font, each core native module and SDL linkage, and all
`.fwork`/`.origin` targets. Startup preflight imports the required native
modules and checks an actual Surface operation without opening a window.
After uploading the device IPA, the workflow stages simulator NumPy and
Pygame binaries and runs `pygame-tests.yml` against the actual app. Its UI test
opens the example, checks screenshots for rendered ball pixels, taps the SDL
view, and stops/reopens the game. Screenshot evidence is uploaded separately;
device packages are restored before cache saving.
On an iPhone, run the Pygame example, tap to move the ball, rotate the device,
background/foreground the app, then Stop and run it again. Also test a game
that throws an exception or ends without `pygame.quit()`, and confirm normal
print/input, NumPy, and native `ui` scripts still run afterward.

## Important limitations

- The SDL2 framework must be present before building PyPhone. The build script requires macOS, Xcode, Git, and network access; it cannot run on the iPhone itself.
- Pygame software/SCALED games use the native bridge described above. Arbitrary PySDL2 applications and other SDL GUI toolkits still need their own iOS-compatible entry point and event/rendering integration. PyPhone's SwiftUI widget renderer remains separate.
- Desktop OpenGL, camera, MIDI, multiple windows, and desktop window-management APIs are unsupported. Native wheels cannot be added through the on-device pure-Python installer.
- Generated XCFrameworks and compiled Pygame modules are local build artifacts and are intentionally not checked into Git.
