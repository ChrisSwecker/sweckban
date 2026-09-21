#!/bin/bash
# Submits Sweckban.app to Apple's notary service, then staples the ticket so the app
# opens cleanly on any Mac — no right-click-Open, no "unidentified developer".
#
# ONE-TIME SETUP (run this yourself: it takes an app-specific password, which this
# script deliberately never sees or stores):
#
#   xcrun notarytool store-credentials sweckban \
#     --apple-id <your-apple-id> --team-id 2V6HCLJ5U4
#
# Create the app-specific password at https://account.apple.com → Sign-In and Security
# → App-Specific Passwords. Override the profile name with SWECKBAN_NOTARY_PROFILE.
set -e
cd "$(dirname "$0")"

APP="Sweckban.app"
PROFILE="${SWECKBAN_NOTARY_PROFILE:-sweckban}"

[ -d "$APP" ] || { echo "No $APP here — run ./build.sh first."; exit 1; }

# Apple rejects anything that isn't Developer ID signed with the hardened runtime.
if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "$APP isn't Developer ID signed — notarization would be rejected."
  echo "Run ./build.sh on a Mac that has the Developer ID certificate installed."
  exit 1
fi
if ! codesign -dvv "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "$APP wasn't signed with the hardened runtime — notarization would be rejected."
  exit 1
fi

# Work from a pristine copy: iCloud Drive re-attaches com.apple.FinderInfo to the bundle
# root, which invalidates the seal even though the signature itself is fine.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto --noextattr --norsrc "$APP" "$WORK/$APP"
codesign --verify --deep --strict "$WORK/$APP"

ZIP="$WORK/Sweckban.zip"
ditto -c -k --keepParent "$WORK/$APP" "$ZIP"

echo "Submitting to Apple — this usually takes a few minutes…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Staple so the app validates without a network round trip, then copy it back.
xcrun stapler staple "$WORK/$APP"
xcrun stapler validate "$WORK/$APP"
rm -rf "$APP"
ditto --noextattr --norsrc "$WORK/$APP" "$APP"

echo ""
spctl -a -vvv -t exec "$APP" || true
echo ""
echo "Done — $APP is notarized and stapled."
echo "To hand it to someone else, zip the stapled bundle:"
echo "  ditto -c -k --keepParent $APP Sweckban.zip"
