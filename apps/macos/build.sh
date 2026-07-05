#!/usr/bin/env bash
#
# build.sh - build Edith.app from the Swift package.
#
#   ./build.sh            # build into dist/Edith.app and launch it
#   ./build.sh --install  # also copy to /Applications and launch from there
#
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Icon: regenerate from the artwork only when missing or stale.
if [ ! -f Resources/AppIcon.icns ] || [ Resources/appicon.png -nt Resources/AppIcon.icns ]; then
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/appicon.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/appicon.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf AppIcon.iconset
fi

APP="dist/Edith.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Edith "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/refresh-usage "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/refresh-usage"
# menu bar / header glyph: trim the icon's canvas margin, then scale
cp Resources/appicon.png "$APP/Contents/Resources/MenuBar.png"
sips -c 942 942 "$APP/Contents/Resources/MenuBar.png" >/dev/null 2>&1
sips -z 80 80 "$APP/Contents/Resources/MenuBar.png" >/dev/null 2>&1
codesign --force --sign - "$APP"

killall Edith 2>/dev/null || true
killall ControlCenter 2>/dev/null || true # pre-rename binary name
if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Edith.app" "/Applications/Control Center.app"
  cp -R "$APP" /Applications/
  open "/Applications/Edith.app"
else
  open "$APP"
fi
