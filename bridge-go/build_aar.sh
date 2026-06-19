#!/usr/bin/env bash
# Builds bridge-go as a gomobile AAR for Android.
# Output: packages/tjena_bridge/android/libs/tjena_bridge.aar
#
# Prerequisites:
#   /home/niklas/go/bin/go           Go 1.23+
#   /home/niklas/go_workspace/bin/gomobile
#   /home/niklas/android-sdk/ndk/27.0.12077973
#
# Usage: ./build_aar.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$REPO_ROOT/packages/tjena_bridge/android/libs"

export PATH="/home/niklas/go/bin:$PATH"
export GOPATH="/home/niklas/go_workspace"
export ANDROID_HOME="/home/niklas/android-sdk"
export ANDROID_SDK_ROOT="/home/niklas/android-sdk"
export ANDROID_NDK_HOME="/home/niklas/android-sdk/ndk/27.0.12077973"

GOMOBILE="$GOPATH/bin/gomobile"

if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning…"
  rm -f "$OUT_DIR"/tjena_bridge.aar "$OUT_DIR"/tjena_bridge-sources.jar
fi

mkdir -p "$OUT_DIR"

cd "$SCRIPT_DIR"

echo "Running go mod tidy…"
go mod tidy

echo "Building gomobile AAR (arm64-v8a, x86_64)…"
# -target android/arm64,android/amd64 covers modern phones + emulator
# -ldflags '-s -w' strips debug symbols for APK size
# -androidapi 24  matches the Flutter plugin minSdk
"$GOMOBILE" bind \
  -target android/arm64,android/amd64 \
  -androidapi 24 \
  -ldflags '-s -w' \
  -o "$OUT_DIR/tjena_bridge.aar" \
  tjena.eu/tjena-bridge/ffi

echo "Done: $OUT_DIR/tjena_bridge.aar"
ls -lh "$OUT_DIR/tjena_bridge.aar"
