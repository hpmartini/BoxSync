#!/bin/bash
# Builds build/BoxSync.app (menu bar app + File Provider extension) with Xcode, signed with the team in project.yml.
# Needs xcodegen (brew install xcodegen) and an Apple ID in Xcode (Settings > Accounts) for that team.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate --quiet
xcodebuild -project BoxSync.xcodeproj -scheme BoxSync -configuration Release \
    -derivedDataPath .build/xcode -allowProvisioningUpdates build -quiet

rm -rf build/BoxSync.app
mkdir -p build
ditto .build/xcode/Build/Products/Release/BoxSync.app build/BoxSync.app
echo "$ROOT/build/BoxSync.app"
