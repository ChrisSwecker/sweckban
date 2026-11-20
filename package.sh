#!/bin/bash
# Builds dist/Sweckban-<version>.dmg: a signed disk image with the app and an
# Applications shortcut, so on another Mac you open it and drag Sweckban across.
#
# If notarization credentials are set up (see notarize.sh), the image is also sent to
# Apple's notary service and the ticket stapled, so it opens on any Mac without a
# Gatekeeper warning. Skip that step with SWECKBAN_NOTARIZE=0.
set -e
cd "$(dirname "$0")"

./build.sh

APP="Sweckban.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
PROFILE="${SWECKBAN_NOTARY_PROFILE:-sweckban}"
mkdir -p dist
DMG="dist/Sweckban-$VERSION.dmg"

SIGN_ID="${SWECKBAN_SIGN_ID-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
             | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

# Stage outside iCloud Drive so no Finder metadata sneaks into the image.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/Sweckban"
ditto --noextattr --norsrc "$APP" "$WORK/Sweckban/$APP"
codesign --verify --deep --strict "$WORK/Sweckban/$APP"
ln -s /Applications "$WORK/Sweckban/Applications"

echo "Creating disk image…"
hdiutil create -volname Sweckban -srcfolder "$WORK/Sweckban" -fs HFS+ \
  -format UDZO -ov "$WORK/Sweckban.dmg" >/dev/null

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$WORK/Sweckban.dmg"
fi

NOTARIZED=0
if [ "${SWECKBAN_NOTARIZE:-1}" != "0" ] && [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "Submitting to Apple — this usually takes a few minutes…"
  if xcrun notarytool submit "$WORK/Sweckban.dmg" --keychain-profile "$PROFILE" --wait \
     | tee "$WORK/notary.log" | grep -q "status: Accepted"; then
    xcrun stapler staple "$WORK/Sweckban.dmg"
    NOTARIZED=1
  else
    cat "$WORK/notary.log"
    echo "note: notarization didn't go through — the image is signed but not notarized."
  fi
fi

cp "$WORK/Sweckban.dmg" "$DMG"
xattr -c "$DMG" 2>/dev/null || true

echo ""
echo "Done: $DMG"
if [ "$NOTARIZED" = 1 ]; then
  echo "Notarized and stapled — it opens on any Mac without warnings."
else
  echo "Not notarized. On the other Mac, after dragging the app to Applications, open it"
  echo "once via System Settings → Privacy & Security → Open Anyway."
fi
