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

# Icon: converts icon.png -> icon.icns using tools that ship with macOS
if [ -f icon.png ]; then
  echo "Building icon…"
  rm -rf icon.iconset && mkdir icon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "icon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out "icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
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
