#!/bin/bash
# Packages build/Release/Sweep.app into a styled drag-to-install DMG.
# Run Scripts/build.sh first (or this script will do it for you).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk -F'"' '{print $2}')
APP="build/Release/Sweep.app"
DMG="dist/Sweep-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
    ./Scripts/build.sh
fi

mkdir -p dist build
rm -f "$DMG"

# DMG background (rendered on demand).
BACKGROUND="build/dmg-background.png"
if [ ! -f "$BACKGROUND" ]; then
    swift Scripts/generate-dmg-background.swift "$BACKGROUND"
fi

create-dmg \
    --volname "Sweep" \
    --volicon "App/Assets.xcassets/AppIcon.appiconset/icon_512.png" \
    --background "$BACKGROUND" \
    --window-pos 200 160 \
    --window-size 560 400 \
    --icon-size 100 \
    --icon "Sweep.app" 140 185 \
    --hide-extension "Sweep.app" \
    --app-drop-link 420 185 \
    --no-internet-enable \
    "$DMG" \
    "$APP"

echo
echo "✓ Created $DMG"
echo "  Install: open the DMG and drag Sweep into Applications."
echo "  Signed with Developer ID. Unless this DMG was notarized"
echo "  (Scripts/release.sh --notarize), recipients bypass Gatekeeper"
echo "  once via right-click → Open."
