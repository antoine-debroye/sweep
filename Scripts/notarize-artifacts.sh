#!/bin/bash
# Notarizes a DMG and staples the ticket to it — and to the .app, if given.
#
#   Scripts/notarize-artifacts.sh <dmg> [app] [keychain-profile]
#
# A single submission notarizes the DMG *and* the app inside it, so stapling the
# standalone .app afterwards works too (its cdhash is already notarized). Staple
# the app before zipping it for the updater so that copy validates offline.
#
# This is the ONE place the notary step lives — both Scripts/release.sh
# (--notarize) and Scripts/notarize.sh call it, so they cannot drift.
#
# Requires the notary profile to have been stored once:
#   xcrun notarytool store-credentials sweep-notary \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-pw
set -euo pipefail

DMG="${1:?usage: notarize-artifacts.sh <dmg> [app] [keychain-profile]}"
APP="${2:-}"
PROFILE="${3:-sweep-notary}"

# Validate everything up front — a bad path must not cost a notary round-trip.
[ -f "$DMG" ] || { echo "Error: no such DMG: $DMG" >&2; exit 1; }
[ -z "$APP" ] || [ -d "$APP" ] || { echo "Error: no such app bundle: $APP" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Error: xcrun not found (install Xcode command-line tools)." >&2; exit 1; }

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Error: notary profile '$PROFILE' not found or invalid." >&2
    echo "Store it once (app-specific password from appleid.apple.com):" >&2
    echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "    --apple-id you@example.com --team-id FC27NYGHX4 --password app-specific-pw" >&2
    exit 1
fi

echo "Submitting $DMG to the Apple notary service (can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
if [ -n "$APP" ]; then
    xcrun stapler staple "$APP"
    echo "✓ Notarized + stapled $DMG and $APP"
else
    echo "✓ Notarized + stapled $DMG"
fi
