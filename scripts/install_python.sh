#!/bin/bash
# Copies the Python standard library into the app and turns each binary
# extension module (.so) into a framework, which iOS requires.
# Finds the stdlib by searching for the "encodings" package, so it does not
# depend on the exact folder layout of the Python.xcframework release.
set -e
APP="${CODESIGNING_FOLDER_PATH%/}"
XC="$PROJECT_DIR/Python.xcframework"

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
  SLICE=$(ls -d "$XC"/ios-*simulator* | head -1)
else
  SLICE=$(ls -d "$XC"/ios-* | grep -v simulator | head -1)
fi
echo "Using slice: $SLICE"

ENC=$(find "$SLICE" -type d -name encodings -path '*/python3.*/encodings' | head -1)
if [ -z "$ENC" ]; then
  echo "error: no python3.x/encodings found under $SLICE. Layout is:" >&2
  find "$XC" -maxdepth 4 -type d | head -60 >&2
  exit 1
fi
STDLIB=$(dirname "$ENC")
PYVER=$(basename "$STDLIB")
echo "Stdlib source: $STDLIB ($PYVER)"

DEST="$APP/python/lib/$PYVER"
mkdir -p "$DEST"
rsync -a --delete "$STDLIB/" "$DEST/"

# If lib-dynload was kept outside the stdlib folder, bring it in.
if [ -z "$(ls -A "$DEST/lib-dynload" 2>/dev/null)" ]; then
  DYN=$(find "$SLICE" -type d -name lib-dynload | head -1)
  if [ -n "$DYN" ]; then
    echo "Copying lib-dynload from $DYN"
    mkdir -p "$DEST/lib-dynload"
    rsync -a "$DYN/" "$DEST/lib-dynload/"
  fi
fi

install_dylib () {
  FULL_EXT="$1"
  RELATIVE_EXT="${FULL_EXT#$APP/}"
  BASE="python/lib/$PYVER/lib-dynload/"
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

if [ -d "$DEST/lib-dynload" ]; then
  find "$DEST/lib-dynload" -name "*.so" | while read -r EXT; do
    install_dylib "$EXT"
  done
fi
echo "Done. Stdlib installed at $DEST"
