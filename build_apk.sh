#!/usr/bin/env bash
# Build Android APK with version + build number auto-injected from pubspec.yaml.
#
# Usage:
#   ./build_apk.sh                    # release arm64
#   ./build_apk.sh universal          # universal APK (all arches, larger)
#
# Outputs:
#   dist/monitor-status-YYMMDDHHMM-vX.Y.Z.apk
#
# Why this exists: app/lib/check_update.dart uses
# `String.fromEnvironment('APP_VERSION')` and `'APP_BUILD'`. Those must be
# passed via --dart-define at build time or the values fall back to the
# hardcoded defaults (2.0.0 / 20).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"
DIST_DIR="$SCRIPT_DIR/dist"
FLAVOR="${1:-arm64}"  # arm64 | universal

# Clear dead proxy vars (e.g. 127.0.0.1:1082) that would otherwise
# break `flutter pub get` and Gradle downloads. Gradle itself is
# handled separately in ~/.gradle/gradle.properties.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy all_proxy ALL_PROXY

# Parse version from pubspec.yaml (strip any CR — pubspec may be CRLF on some setups)
PUBSPEC="$APP_DIR/pubspec.yaml"
VERSION_LINE=$(grep -E '^version:' "$PUBSPEC" | head -1 | tr -d '\r')
VERSION=$(echo "$VERSION_LINE" | sed -E 's/^version:[[:space:]]*//' | tr -d '\r')
NAME=$(echo "$VERSION" | sed -E 's/\+.*//' | tr -d '\r')
BUILD=$(echo "$VERSION" | sed -E 's/^.*\+//' | tr -d '\r')

if [[ -z "$NAME" || -z "$BUILD" ]]; then
  echo "ERROR: could not parse version from $PUBSPEC" >&2
  echo "  line was: $VERSION_LINE" >&2
  exit 1
fi

echo "==> version: $NAME  build: $BUILD  flavor: $FLAVOR"

# Source Flutter env
source "$HOME/.flutter_env.sh"

cd "$APP_DIR"
case "$FLAVOR" in
  arm64)
    flutter build apk --release \
      --target-platform android-arm64 \
      --dart-define=GLASS_STYLE=solid \
      --dart-define=APP_VERSION="$NAME" \
      --dart-define=APP_BUILD="$BUILD"
    ;;
  universal)
    flutter build apk --release \
      --dart-define=GLASS_STYLE=solid \
      --dart-define=APP_VERSION="$NAME" \
      --dart-define=APP_BUILD="$BUILD"
    ;;
  *)
    echo "unknown flavor: $FLAVOR (use arm64 or universal)" >&2
    exit 1
    ;;
esac

# Stage to dist/ with versioned filename
TS=$(date +%y%m%d%H%M)
APK_SRC="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_DST="$DIST_DIR/monitor-status-${TS}-v${NAME}.apk"
mkdir -p "$DIST_DIR"
cp "$APK_SRC" "$APK_DST"
echo "==> staged: $APK_DST  ($(du -h "$APK_DST" | cut -f1))"

# Update SHA256SUMS (APK + the two agent binaries)
cd "$DIST_DIR"
shasum -a 256 \
  "$(basename "$APK_DST")" \
  agent-linux-amd64 \
  agent-linux-arm64 \
  > SHA256SUMS
echo "==> updated SHA256SUMS"
