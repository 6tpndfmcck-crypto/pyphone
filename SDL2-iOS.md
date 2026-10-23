# SDL2 support in PyPhone

PyPhone runs Python inside an iOS app, so installing the pure-Python `PySDL2` wrapper is not enough: iOS also needs a native SDL2 framework compiled for iOS. This repository does not commit that compiled binary.

## Build SDL2 and prepare PyPhone

On a Mac with Xcode and its command-line tools installed, from the repository root run:

```sh
bash scripts/build_sdl2_xcframework.sh
```

The script checks out the pinned official SDL2 source release (`release-2.32.10`), builds its `xcFramework-iOS` scheme for iOS device and simulator, and copies `SDL2.xcframework` to the repository root. To use another SDL2 source tag, set `SDL2_TAG` when running the script.

Then regenerate the Xcode project using the same XcodeGen workflow you normally use and build/archive PyPhone. `project.yml` links and embeds `SDL2.xcframework`; `PythonBridge.m` sets `PYSDL2_DLL_PATH` to the embedded `SDL2.framework` before Python initializes, so PySDL2 can locate the native library.

## Important limitations

- The SDL2 framework must be present before building PyPhone. The build script requires macOS, Xcode, Git, and network access; it cannot run on the iPhone itself.
- This packages SDL2 and configures PySDL2's library search path. It does not guarantee every SDL2 video/audio backend or every SDL-based GUI toolkit works on iOS. SDL2 applications must still use an iOS-compatible SDL entry point and event/rendering integration; PyPhone's existing SwiftUI widget renderer is a separate UI system.
- The generated `SDL2.xcframework` is a local build artifact and is intentionally not checked into Git.
