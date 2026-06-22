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

echo "Building gomobile AAR (arm64-v8a)…"
# arm64 only: the Signal bridge links libsignal_ffi.a which is only present for
# arm64 (internal/signal_libs/arm64). amd64/emulator would fail to link.
# -ldflags '-s -w' strips debug symbols for APK size
# -androidapi 24  matches the Flutter plugin minSdk
"$GOMOBILE" bind \
  -target android/arm64 \
  -androidapi 24 \
  -ldflags '-s -w' \
  -o "$OUT_DIR/tjena_bridge.aar" \
  tjena.eu/tjena-bridge/ffi

echo "Done: $OUT_DIR/tjena_bridge.aar"
ls -lh "$OUT_DIR/tjena_bridge.aar"

# CRITICAL: the plugin references libs/ as compileOnly, but the APK actually
# PACKAGES the AAR from android/app/libs/ (implementation fileTree). Both copies
# must be updated or the runtime AAR goes stale while compilation still succeeds
# against the new one — producing NoSuchMethodError crashes at runtime.
APP_LIBS="$REPO_ROOT/android/app/libs"
mkdir -p "$APP_LIBS"
cp "$OUT_DIR/tjena_bridge.aar" "$APP_LIBS/tjena_bridge.aar"
echo "Copied runtime AAR: $APP_LIBS/tjena_bridge.aar"
ls -lh "$APP_LIBS/tjena_bridge.aar"
