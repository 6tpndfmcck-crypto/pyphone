#!/bin/bash
# Copies the Python standard library into the app and turns each binary
# extension module (.so) into a framework, which iOS requires.
set -e
APP="$CODESIGNING_FOLDER_PATH"
XC="$PROJECT_DIR/Python.xcframework"
STDLIB="$PROJECT_DIR/python-stdlib/python3.13"

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
  SLICE="ios-arm64_x86_64-simulator"
  ARCH="${CURRENT_ARCH:-arm64}"
  # Some Xcode aggregate/script phases report undefined_arch; arm64 is the
  # correct default for current Apple-silicon simulator builds.
  if [ "$ARCH" = "undefined_arch" ]; then ARCH="arm64"; fi
  LIBROOT="$XC/$SLICE/lib-$ARCH"
else
  SLICE="ios-arm64"
  LIBROOT="$XC/$SLICE/lib-arm64"
fi

# BeeWare's XCFramework stores Python files in the architecture-specific
# lib-arm64/lib-x86_64 folder. Older package layouts may put them directly
# under lib/, so use that only when it contains the expected Python tree.
if [ ! -d "$LIBROOT/python3.13/lib-dynload" ] && [ -d "$XC/$SLICE/lib/python3.13/lib-dynload" ]; then
  LIBROOT="$XC/$SLICE/lib"
fi
if [ ! -d "$LIBROOT/python3.13/lib-dynload" ]; then
  echo "error: Python native modules directory not found under $LIBROOT" >&2
  ls -R "$XC/$SLICE" | head -80 >&2
  exit 1
fi
if [ ! -f "$STDLIB/encodings/__init__.py" ]; then
  echo "error: Python standard library not staged at $STDLIB" >&2
  exit 1
fi

mkdir -p "$APP/python/lib"
# This directory contains libpython3.13.dylib.
rsync -au --delete "$LIBROOT/" "$APP/python/lib/"
# The support archive's standard library is separate from the XCFramework's
# lib/ directory, so copy it into the expected python/lib/python3.13 location.
mkdir -p "$APP/python/lib/python3.13"
# Merge the pure-Python standard library into the XCFramework's Python
# library tree. Do NOT use --delete here: the XCFramework may be the source
# of lib-dynload native modules, and deleting files absent from STDLIB would
# remove modules such as math before they can be bundled as iOS frameworks.
rsync -au "$STDLIB/" "$APP/python/lib/python3.13/"

DYNLOAD="$APP/python/lib/python3.13/lib-dynload"
if [ ! -d "$DYNLOAD" ]; then
  echo "error: Python native extension directory is missing: $DYNLOAD" >&2
  echo "Looking for lib-dynload in the support archive and XCFramework:" >&2
  find "$PROJECT_DIR/py" "$XC" -type d -name 'lib-dynload' -print 2>/dev/null | head -30 >&2
  exit 1
fi
if ! find "$DYNLOAD" -maxdepth 1 -type f -name 'math*.so' -print -quit | grep -q .; then
  echo "error: math native extension is missing from $DYNLOAD" >&2
  find "$DYNLOAD" -maxdepth 1 -type f -name '*.so' -print | head -50 >&2
  exit 1
fi

PYVER="python3.13"
test -d "$APP/python/lib/$PYVER" || { echo "error: $PYVER was not installed under $APP/python/lib" >&2; find "$APP/python/lib" -maxdepth 3 -type d -print | head -50 >&2; exit 1; }
echo "Python lib folder: $PYVER"

install_dylib () {
  BASE="$1"
  FULL_EXT="$2"
  RELATIVE_EXT="${FULL_EXT#$APP/}"
  PYTHON_EXT="${RELATIVE_EXT#$BASE}"
  MODULE=$(echo "$PYTHON_EXT" | cut -d "." -f 1 | tr "/" ".")
  BUNDLE_ID=$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$MODULE" | tr "_" "-")
  FW="Frameworks/$MODULE.framework"

  if [ ! -d "$APP/$FW" ]; then
    mkdir -p "$APP/$FW"
    cat > "$APP/$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$MODULE</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$MODULE</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$IPHONEOS_DEPLOYMENT_TARGET</string>
</dict></plist>
PLIST
  fi

  mv "$FULL_EXT" "$APP/$FW/$MODULE"
  echo "$FW/$MODULE" > "${FULL_EXT%.so}.fwork"
  echo "${RELATIVE_EXT%.so}.fwork" > "$APP/$FW/$MODULE.origin"
}

find "$APP/python/lib/$PYVER/lib-dynload" -name "*.so" | while read -r EXT; do
  install_dylib "python/lib/$PYVER/lib-dynload/" "$EXT"
done

# Binary modules from installed packages (numpy etc.)
if [ -d "$APP/app_packages" ]; then
  echo "Install package extension modules..."
  find "$APP/app_packages" -name "*.so" | while read -r EXT; do
    install_dylib "app_packages/" "$EXT"
  done
fi
echo "Done."
