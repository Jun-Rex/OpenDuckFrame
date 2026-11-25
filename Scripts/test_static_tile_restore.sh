#!/bin/bash
# Real GPU static-tile restoration on synthetic buffers; needs the built Debug app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
DYLIB="${ODF_TEST_DEBUG_DYLIB:-$PRODUCTS/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPStaticTileRestorerTests.mm" \
  -framework Foundation -framework Metal -framework CoreVideo \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$DYLIB"
