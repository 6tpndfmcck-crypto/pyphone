#!/usr/bin/env bash
# Build the official SDL2 iOS device + simulator XCFramework used by PySDL2.
# Requires macOS, Xcode command-line tools, git, and network access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${SDL2_BUILD_DIR:-$ROOT/.build/sdl2}"
SOURCE="$BUILD_ROOT/source"
DERIVED="$BUILD_ROOT/derived"
TAG="${SDL2_TAG:-release-2.32.10}"

mkdir -p "$BUILD_ROOT"
if [ ! -d "$SOURCE/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/libsdl-org/SDL.git "$SOURCE"
else
  git -C "$SOURCE" fetch --depth 1 origin "$TAG"
  git -C "$SOURCE" checkout --detach FETCH_HEAD
fi

PROJECT="$SOURCE/Xcode/SDL/SDL.xcodeproj"
if [ ! -d "$PROJECT" ]; then
  echo "error: SDL2 Xcode project not found at $PROJECT" >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme xcFramework-iOS \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build

BUILT="$(find "$SOURCE/Xcode/SDL/build" "$ROOT/build" "$DERIVED/Build/Products" -type d -name SDL2.xcframework -print -quit 2>/dev/null || true)"
if [ -z "$BUILT" ]; then
  echo "error: xcodebuild succeeded but SDL2.xcframework was not found under $DERIVED/Build/Products" >&2
  find "$SOURCE/Xcode/SDL/build" "$ROOT/build" "$DERIVED/Build/Products" -maxdepth 5 -print 2>/dev/null | head -100 >&2 || true
  exit 1
fi

DEST="$ROOT/SDL2.xcframework"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
echo "Built SDL2 XCFramework at: $DEST"
echo "Next: regenerate the Xcode project and build/archive PyPhone."
