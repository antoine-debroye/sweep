#!/bin/bash
# Signs and notarizes Sweep for warning-free distribution.
# Requires a paid Apple Developer account. One-time setup:
#   1. Create a "Developer ID Application" certificate in your Apple Developer
#      account and install it in your login Keychain.
#   2. Store notary credentials once:
#        xcrun notarytool store-credentials sweep-notary \
#          --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#   3. Run: TEAM_ID=TEAMID ./Scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple Developer Team ID}"
IDENTITY="Developer ID Application"
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk -F'"' '{print $2}')
APP="build/Release/Sweep.app"
DMG="dist/Sweep-${VERSION}.dmg"

[ -d "$APP" ] || ./Scripts/build.sh

# Hardened runtime is required for notarization.
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP/Contents/MacOS/SweepHelper"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP/Contents/Frameworks/SweepCore.framework"
codesign --force --options runtime --timestamp \
    --entitlements App/Sweep.entitlements \
    --sign "$IDENTITY" "$APP"

rm -f "$DMG"
./Scripts/make-dmg.sh

xcrun notarytool submit "$DMG" --keychain-profile sweep-notary --wait
xcrun stapler staple "$DMG"

echo "✓ Notarized $DMG — distributable without Gatekeeper warnings."
