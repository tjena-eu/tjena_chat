#!/usr/bin/env bash
# Builds an UNMODIFIED upstream mautrix-whatsapp tag for android/arm64.
#
# Output: out/<tag>/libmautrixwhatsapp.so, librelay.so and libwacall.so
# (executables named .so so that Android extracts them to nativeLibraryDir,
# where exec is allowed), also copied into bridge_app's jniLibs.
#
# Usage: ./build.sh [tag]          default tag: see PINNED_TAG below
# Env:   ANDROID_NDK   path to NDK (default: newest in ~/android-sdk/ndk)
#        API           min Android API level (default 29 = Android 10)
set -euo pipefail

PINNED_TAG="v0.2610.0"
TAG="${1:-$PINNED_TAG}"
API="${API:-29}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/.work"
OUT="$HERE/out/$TAG"

if [[ -z "${ANDROID_NDK:-}" ]]; then
  ANDROID_NDK="$(ls -d "$HOME"/android-sdk/ndk/* | sort -V | tail -1)"
fi
CC="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
[[ -x "$CC" ]] || { echo "NDK clang not found: $CC" >&2; exit 1; }

GO="${GO:-$(command -v go || echo "$HOME/go/bin/go")}"
export GOTOOLCHAIN=auto

mkdir -p "$WORK" "$OUT"
SRC="$WORK/whatsapp-$TAG"
if [[ ! -d "$SRC" ]]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/mautrix/whatsapp "$SRC"
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
# Refuse to build a dirty tree: the bridge must stay unmodified.
if [[ -n "$(git -C "$SRC" status --porcelain)" ]]; then
  echo "Source tree $SRC is modified; refusing to build." >&2; exit 1
fi

MAUTRIX_VERSION="$(cd "$SRC" && "$GO" list -m -f '{{.Version}}' maunium.net/go/mautrix)"
BUILD_TIME="$(date -u -Iseconds)"
LDFLAGS="-s -w \
 -X main.Tag=$TAG -X main.Commit=$COMMIT -X 'main.BuildTime=$BUILD_TIME' \
 -X 'maunium.net/go/mautrix.GoModVersion=$MAUTRIX_VERSION'"

echo "Building mautrix-whatsapp $TAG ($COMMIT) for android/arm64 API $API"
(
  cd "$SRC"
  CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
    CGO_CFLAGS="-O2 -DSQLITE_ENABLE_FTS5" \
    "$GO" build -trimpath -tags goolm,sqlite_omit_load_extension \
      -ldflags "$LDFLAGS" -o "$OUT/libmautrixwhatsapp.so" ./cmd/mautrix-whatsapp
)
echo "$TAG $COMMIT" > "$OUT/VERSION"

# Our relay (personal-bridge/relay), same toolchain. CGO so Go uses bionic's
# DNS resolver (Android has no /etc/resolv.conf).
echo "Building bridge-relay for android/arm64"
(
  cd "$HERE/../relay"
  CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
    "$GO" build -trimpath -ldflags "-s -w" -o "$OUT/librelay.so" .
)

# WhatsApp calls daemon (personal-bridge/wacall). -checklinkname=0: pion's
# Android network-interface lookup (wlynxg/anet) links to a net internal.
echo "Building wacall for android/arm64"
(
  cd "$HERE/../wacall"
  CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
    "$GO" build -trimpath -ldflags "-s -w -checklinkname=0" -o "$OUT/libwacall.so" .
)

# Install into the bridge app (jniLibs is git-ignored).
JNI="$HERE/../bridge_app/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI"
cp "$OUT/libmautrixwhatsapp.so" "$OUT/librelay.so" "$OUT/libwacall.so" "$JNI/"
file "$OUT/libmautrixwhatsapp.so" "$OUT/librelay.so" "$OUT/libwacall.so" || true
ls -la "$OUT"
