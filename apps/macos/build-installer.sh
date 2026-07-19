#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}

RELEASE="${EDITH_RELEASE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=1 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

SIGN_FLAGS=""
if [ "$RELEASE" = 1 ]; then
  SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  case "$SIGN_IDENTITY" in
    *"Developer ID Application"*) ;;
    *)
      echo "release build blocked: a Developer ID Application signing identity is required" >&2
      exit 1
      ;;
  esac
  SIGN_FLAGS="--options runtime --timestamp"
else
  SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Edith Dev')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

swift build -c release --product EdithInstaller

APP="dist/Edith Installer.app"
DMG_ROOT="installer-dmg-root"
rm -rf "$APP" "$DMG_ROOT"
rm -f dist/EdithInstaller.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DMG_ROOT"
cp .build/release/EdithInstaller "$APP/Contents/MacOS/"
cp Resources/InstallerInfo.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R .build/release/Edith_EdithKit.bundle "$APP/Contents/Resources/"

codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$APP"

cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "Edith Installer" -srcfolder "$DMG_ROOT" -format UDZO \
  dist/EdithInstaller.dmg
rm -rf "$DMG_ROOT"
