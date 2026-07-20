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
# network); --options runtime enables the Hardened Runtime, required for
# notarization (Scripts/release.sh --notarize) and harmless otherwise.
IDENTITY="Developer ID Application"
# --identifier is REQUIRED for the helper: it is a bare Mach-O with no Info.plist,
# so codesign would otherwise derive the identifier from the filename
# ("SweepHelper"). SMAppService requires the daemon's signing identifier to match
# its LaunchDaemon Label (com.debroye.sweep.helper) — a mismatch makes macOS
# SIGKILL it at launch with a Launch Constraint Violation, and launchd then
# respawns it in a loop.
codesign --force --timestamp --options runtime \
    --identifier com.debroye.sweep.helper \
    --sign "$IDENTITY" "$OUT/Contents/MacOS/SweepHelper"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$OUT/Contents/Frameworks/SweepCore.framework"
codesign --force --timestamp --options runtime --entitlements App/Sweep.entitlements --sign "$IDENTITY" "$OUT"

echo
echo "✓ Built build/Release/Sweep.app"
codesign -dvvv build/Release/Sweep.app 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature"
