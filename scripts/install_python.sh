#!/bin/bash
# Copies the Python standard library into the app and turns each binary
# extension module (.so) into a framework, which iOS requires.
set -e
APP="$CODESIGNING_FOLDER_PATH"
XC="$PROJECT_DIR/Python.xcframework"
STDLIB="$PROJECT_DIR/python-stdlib/python3.13"

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
  SLICE="ios-arm64_x86_64-simulator"
else
  SLICE="ios-arm64"
fi

if [ ! -d "$XC/$SLICE/lib" ]; then
  echo "error: $XC/$SLICE/lib not found. Layout is:" >&2
  ls -R "$XC" | head -40 >&2
  exit 1
fi
if [ ! -f "$STDLIB/encodings/__init__.py" ]; then
  echo "error: Python standard library not staged at $STDLIB" >&2
  exit 1
fi

mkdir -p "$APP/python/lib"
# This directory contains libpython3.13.dylib.
rsync -au --delete "$XC/$SLICE/lib/" "$APP/python/lib/"
# The support archive's standard library is separate from the XCFramework's
# lib/ directory, so copy it into the expected python/lib/python3.13 location.
mkdir -p "$APP/python/lib/python3.13"
# Copy the complete standard library, including native extension modules.
# The loop below converts each .so in lib-dynload into an iOS framework.
rsync -au --delete "$STDLIB/" "$APP/python/lib/python3.13/"
test -d "$APP/python/lib/python3.13/lib-dynload" || {
  echo "error: Python support archive has no lib-dynload directory under $STDLIB" >&2
  find "$STDLIB" -maxdepth 3 -type d -name 'lib-dynload' -print >&2
  exit 1
}

PYVER=$(ls -1 "$APP/python/lib" | grep '^python3' | head -1)
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
