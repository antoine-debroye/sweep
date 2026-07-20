#!/bin/bash
# Builds, packages, notarizes and staples a DMG **without cutting a release** —
# no version bump, no tag, no push, no GitHub release. Use this for a one-off
# warning-free DMG you want to hand to someone.
#
#   Scripts/notarize.sh
#
# To cut an actual release, use:  Scripts/release.sh <version> --notarize
#
# Signing is NOT duplicated here: Scripts/build.sh is the single source of truth
# (Developer ID identity, hardened runtime, and the helper's --identifier, which
# must match its LaunchDaemon Label or SMAppService refuses to launch it).
# The notary step lives in Scripts/notarize-artifacts.sh, shared with release.sh.
#
# One-time setup: store the notary credentials (app-specific password from
# appleid.apple.com):
#   xcrun notarytool store-credentials sweep-notary \
#     --apple-id you@example.com --team-id FC27NYGHX4 --password app-specific-pw
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build.sh

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk -F'"' '{print $2}')
DMG="dist/Sweep-${VERSION}.dmg"

rm -f "$DMG"
./Scripts/make-dmg.sh

./Scripts/notarize-artifacts.sh "$DMG" build/Release/Sweep.app

echo
echo "✓ $DMG is notarized — distributable without Gatekeeper warnings."
