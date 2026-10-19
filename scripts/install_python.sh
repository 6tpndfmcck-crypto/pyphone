#!/bin/bash
# Copies the Python standard library into the app and turns each binary
# extension module (.so) into a framework, which iOS requires.
#
# Package layout (BeeWare Python-Apple-support 3.13):
#   Python.xcframework/lib/python3.13/                      <- shared pure-Python stdlib
#   Python.xcframework/<slice>/lib-<arch>/python3.13/lib-dynload/  <- per-slice .so modules
set -e
APP="${CODESIGNING_FOLDER_PATH%/}"
XC="$PROJECT_DIR/Python.xcframework"

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
  SLICE=$(ls -d "$XC"/ios-*simulator* | head -1)
else
  SLICE=$(ls -d "$XC"/ios-* | grep -v simulator | head -1)
fi
echo "Using slice: $SLICE"

# Shared stdlib: any python3.x folder that contains "encodings".
ENC=$(find "$XC" -type d -path '*/python3.*/encodings' | sort | head -1)
if [ -z "$ENC" ]; then
  echo "error: no python3.x/encodings found under $XC. Layout is:" >&2
  find "$XC" -maxdepth 4 -type d | head -60 >&2
  exit 1
fi
STDLIB=$(dirname "$ENC")
PYVER=$(basename "$STDLIB")
echo "Stdlib source: $STDLIB ($PYVER)"

# Binary modules for this slice (prefer arm64).
DYN=$(find "$SLICE" -type d -name lib-dynload | sort | grep arm64 | head -1 || true)
[ -z "$DYN" ] && DYN=$(find "$SLICE" -type d -name lib-dynload | sort | head -1)
echo "lib-dynload source: ${DYN:-none found}"

DEST="$APP/python/lib/$PYVER"
mkdir -p "$DEST"
rsync -a --delete --exclude '/test/' --exclude '__pycache__/' "$STDLIB/" "$DEST/"
if [ -n "$DYN" ]; then
  mkdir -p "$DEST/lib-dynload"
  rsync -a "$DYN/" "$DEST/lib-dynload/"
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
