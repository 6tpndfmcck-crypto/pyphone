#!/bin/bash
# Copies the Python standard library into the app and converts binary
# extension modules into frameworks, using the helper BeeWare ships
# inside Python.xcframework.
set -e
source "$PROJECT_DIR/Python.xcframework/build/build_utils.sh"
install_python Python.xcframework app
