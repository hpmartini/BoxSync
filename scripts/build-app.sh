#!/bin/bash
# Builds the release executable and wraps it into build/BoxSync.app (signed with "BoxSync Local Signing" if present, else ad hoc).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/BoxSync.app"

swift build --package-path "$ROOT" -c release --product BoxSyncApp
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/BoxSyncApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/BoxSyncApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
IDENTITY="BoxSync Local Signing"   # created by scripts/make-signing-cert.sh
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force -s "$IDENTITY" "$APP"
else
    echo "No \"$IDENTITY\" certificate, signing ad hoc (run scripts/make-signing-cert.sh once for a stable signature)" >&2
    codesign --force -s - "$APP"
fi
echo "$APP"
