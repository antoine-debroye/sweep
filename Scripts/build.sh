#!/bin/bash
# Builds Sweep.app (Release, ad-hoc signed) into build/Release/Sweep.app
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

xcodebuild \
    -project Sweep.xcodeproj \
    -scheme Sweep \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    build

APP="build/DerivedData/Build/Products/Release/Sweep.app"
mkdir -p build/Release
rm -rf build/Release/Sweep.app
cp -R "$APP" build/Release/Sweep.app

# Re-sign the whole bundle ad-hoc so the embedded helper and framework agree.
codesign --force --deep --sign - build/Release/Sweep.app

echo
echo "✓ Built build/Release/Sweep.app"
codesign -dv build/Release/Sweep.app 2>&1 | grep -E "Identifier|Signature"
