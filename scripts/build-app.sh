#!/bin/bash
# Builds the release executable and wraps it into build/BoxSync.app (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/BoxSync.app"

swift build --package-path "$ROOT" -c release --product BoxSyncApp
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/BoxSyncApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/BoxSyncApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "$APP"
