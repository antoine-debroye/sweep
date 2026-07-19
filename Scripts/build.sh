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
OUT="build/Release/Sweep.app"

# Re-seal with the Developer ID identity, inner components first so the embedded
# helper (copied in by a build phase after signing) and the framework agree and
# the outer signature covers them. A stable Team-signed identity is what lets the
# updater's Keychain "Always Allow" persist across self-updates — ad-hoc changes
# cdhash every build and re-prompts. --timestamp adds a secure timestamp (needs
# network); notarization (Scripts/notarize.sh) additionally applies --options runtime.
IDENTITY="Developer ID Application"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/Contents/MacOS/SweepHelper"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/Contents/Frameworks/SweepCore.framework"
codesign --force --timestamp --entitlements App/Sweep.entitlements --sign "$IDENTITY" "$OUT"

echo
echo "✓ Built build/Release/Sweep.app"
codesign -dvvv build/Release/Sweep.app 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature"
