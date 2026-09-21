#!/bin/bash
# Builds Sweckban.app — requires Xcode Command Line Tools (xcode-select --install)
set -e
cd "$(dirname "$0")"

APP="Sweckban.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O main.swift -o "$APP/Contents/MacOS/Sweckban"

cp sweckban.html "$APP/Contents/Resources/"
cp Info.plist  "$APP/Contents/"

# Icon: vector art -> icon.icns. 16/32pt render from icon-small.svg, whose bars are
# chunkier and further apart — the full art's bars land on ~2 device pixels there and
# smear together. 128pt and up use icon.svg. Regenerate both with `node make-icon.js`.
# Without rsvg-convert we downscale icon.png instead: softer small sizes, no extra tools.
if [ -f icon.png ]; then
  echo "Building icon…"
  rm -rf icon.iconset && mkdir icon.iconset
  RSVG="$(command -v rsvg-convert || true)"
  [ -n "$RSVG" ] || echo "  note: rsvg-convert not found — downscaling icon.png (brew install librsvg for crisper 16/32pt)"
  render() {  # size, output name, svg source
    if [ -n "$RSVG" ] && [ -f "$3" ]; then
      "$RSVG" -w "$1" -h "$1" "$3" -o "icon.iconset/$2"
    else
      sips -z "$1" "$1" icon.png --out "icon.iconset/$2" >/dev/null
    fi
  }
  render 16   icon_16x16.png      icon-small.svg
  render 32   icon_16x16@2x.png   icon-small.svg
  render 32   icon_32x32.png      icon-small.svg
  render 64   icon_32x32@2x.png   icon-small.svg
  render 128  icon_128x128.png    icon.svg
  render 256  icon_128x128@2x.png icon.svg
  render 256  icon_256x256.png    icon.svg
  render 512  icon_256x256@2x.png icon.svg
  render 512  icon_512x512.png    icon.svg
  render 1024 icon_512x512@2x.png icon.svg
  iconutil -c icns icon.iconset -o "$APP/Contents/Resources/icon.icns"
  rm -rf icon.iconset
fi

# Ad-hoc sign so macOS treats the bundle as intact.
# Clear extended attributes first — stray xattrs make codesign fail to seal
# resources ("resource fork … not allowed" / "code has no resources").
find "$APP" -exec xattr -c {} \; 2>/dev/null
codesign --force --deep --sign - "$APP"
# Strict verify is a sanity check, not a gate: macOS keeps re-attaching benign
# com.apple.FinderInfo/provenance to items (esp. on the Desktop), which trips
# --strict even though the ad-hoc signature is fine for local launch.
codesign --verify --deep --strict "$APP" \
  || echo "note: strict verify flagged Finder metadata (benign for local use)"

echo ""
echo "Done: $APP"
echo "Drag it to /Applications (or keep it anywhere) and double-click."
echo "Data file: ~/Desktop/Sweckban/sweckban-data.json (edit DATA_DIR in main.swift to change)"
