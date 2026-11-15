#!/bin/bash
# Opens an owned synthetic test window for 23–26 seconds. Does not capture the screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 OUTPUT.json [steady|jitter|source25|auto24|auto25|auto30] [0|720] [20|90 observation-seconds]" >&2
  exit 2
fi
PROFILE="${2:-jitter}"
PROCESSING_PRESET="${3:-0}"
OBSERVATION_SECONDS="${4:-20}"
case "$OBSERVATION_SECONDS" in 20|90) ;; *) echo 'expected observation duration 20 or 90 seconds' >&2; exit 2 ;; esac
case "$PROCESSING_PRESET" in 0|720) ;; *) echo 'expected processing preset 0 or 720' >&2; exit 2 ;; esac
case "$PROFILE" in steady|jitter|source25|auto24|auto25|auto30) ;; *) echo 'expected steady, jitter, source25, auto24, auto25 or auto30' >&2; exit 2 ;; esac
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
DYLIB="$PRODUCTS/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib"
[ -f "$DYLIB" ] || { echo 'Build the Debug app first.' >&2; exit 2; }
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
PROBE="$TEST_DIR/Probe.app/Contents"
mkdir -p "$PROBE/MacOS" "$PROBE/Resources"
# The production presenter loads its Metal library from the main bundle.
cp "$PRODUCTS/OpenDuckFrame.app/Contents/Resources/default.metallib" "$PROBE/Resources/"
xcrun clang++ -O2 -std=c++17 -fobjc-arc -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPAppleLivePresentationProbe.mm" \
  -framework AppKit -framework CoreVideo -framework CoreMedia -framework QuartzCore \
  -Wl,-rpath,"$PRODUCTS" -o "$PROBE/MacOS/probe"
"$PROBE/MacOS/probe" "$DYLIB" "$1" "$PROFILE" "$PROCESSING_PRESET" "$OBSERVATION_SECONDS"
