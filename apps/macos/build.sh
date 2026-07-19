#!/usr/bin/env bash
#
#   ./build.sh                # build into dist/Edith.app and launch it
#   ./build.sh --install      # also copy to /Applications and launch from there
#   ./build.sh --no-open      # build only, don't launch (used by CI)
#   ./build.sh --pr 42        # resolve PR #42's branch via gh, build it from the
#                             # worktree it is checked out in (created if
#                             # missing), and install
#   ./build.sh --branch name  # same, for a branch named directly
#
# Signing: the first available of a "Developer ID Application" cert, a
# self-signed "Edith Dev" cert, or an "Apple Development" cert is picked up
# automatically (or set EDITH_SIGN_IDENTITY) so its designated requirement is
# stable across builds and TCC grants + SMAppService login-item registration
# survive reinstalls. Without any identity, signing falls back to ad-hoc ("-"),
# whose requirement is pinned to the binary hash and so resets TCC grants
# (Screen Recording, ...) on every reinstall.
set -euo pipefail
cd "$(dirname "$0")"

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}
INSTALL=0 NO_OPEN=0 PR="" BRANCH="" RELEASE="${EDITH_RELEASE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --no-open) NO_OPEN=1 ;;
    --release) RELEASE=1 ;;
    --pr) PR="${2:?--pr needs a PR number}"; shift ;;
    --branch) BRANCH="${2:?--branch needs a branch name}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

SIGN_FLAGS=""
if [ "$RELEASE" = 1 ]; then
  SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  case "$SIGN_IDENTITY" in
    *"Developer ID Application"*)
      SIGN_FLAGS="--options runtime --timestamp"
      ;;
    *)
      if [ "${EDITH_RELEASE_ALLOW_DEV_SIGNING:-0}" = 1 ]; then
        echo "WARNING: release build without Developer ID signing" >&2
        echo "         (EDITH_RELEASE_ALLOW_DEV_SIGNING=1); artifact will not be" >&2
        echo "         notarizable and Gatekeeper will warn on other Macs." >&2
        SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-}"
        SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Edith Dev')}"
        SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
        SIGN_IDENTITY="${SIGN_IDENTITY:--}"
      else
        echo "release build blocked: a Developer ID Application signing identity is required" >&2
        echo "set EDITH_RELEASE_ALLOW_DEV_SIGNING=1 to knowingly release with dev signing" >&2
        exit 1
      fi
      ;;
  esac
else
  SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Edith Dev')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

if [ -n "$PR" ]; then
  BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName)"
  echo "PR #$PR -> branch $BRANCH"
fi

if [ -n "$BRANCH" ]; then
  INSTALL=1
  if [ "$BRANCH" != "$(git branch --show-current)" ]; then
    ROOT="$(git worktree list --porcelain \
      | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
    if [ -z "$ROOT" ]; then
      git fetch origin "$BRANCH" >/dev/null 2>&1 || true
      git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
        || git branch --track "$BRANCH" "origin/$BRANCH"
      MAIN="$(git worktree list --porcelain | head -1 | cut -c10-)"
      ROOT="$MAIN/../edith-${BRANCH//\//-}"
      echo "creating worktree $ROOT for $BRANCH"
      git worktree add "$ROOT" "$BRANCH"
    fi
    echo "building from $ROOT"
    exec "$ROOT/apps/macos/build.sh" --install
  fi
fi

swift build -c release

# Icon: regenerate from the artwork only when missing or stale.
ARTWORK="Sources/Edith/Resources/appicon.png"
if [ ! -f Resources/AppIcon.icns ] || [ "$ARTWORK" -nt Resources/AppIcon.icns ]; then
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ARTWORK" --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ARTWORK" --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf AppIcon.iconset
fi

APP="dist/Edith.app"
LOGIN_ITEMS="$APP/Contents/Library/LoginItems"
HELPER="$LOGIN_ITEMS/Edith.app"
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name Sparkle.framework -print -quit)"
[ -n "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework not found in SwiftPM artifacts" >&2; exit 1; }
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
rm -rf "$LOGIN_ITEMS/Edith"Helper.app
cp .build/release/Edith "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R .build/release/Edith_EdithKit.bundle "$APP/Contents/Resources/"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp .build/release/EdithHelper "$HELPER/Contents/MacOS/Edith"
cp Resources/HelperInfo.plist "$HELPER/Contents/Info.plist"
cp Resources/AppIcon.icns "$HELPER/Contents/Resources/"
cp -R .build/release/Edith_EdithKit.bundle "$HELPER/Contents/Resources/"
cp Resources/refresh-usage "$HELPER/Contents/Resources/"
chmod +x "$HELPER/Contents/Resources/refresh-usage"
# menu bar / header glyph: trim the icon's canvas margin, then scale
cp "$ARTWORK" "$HELPER/Contents/Resources/MenuBar.png"
sips -c 942 942 "$HELPER/Contents/Resources/MenuBar.png" >/dev/null 2>&1
sips -z 80 80 "$HELPER/Contents/Resources/MenuBar.png" >/dev/null 2>&1

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "WARNING: no signing identity found; signing ad-hoc. The code signature" >&2
  echo "         changes every build, so macOS TCC permission grants (Screen" >&2
  echo "         Recording, Accessibility, Calendar, ...) reset on every reinstall." >&2
  echo "         Use a Developer ID / Apple Development / self-signed 'Edith Dev'" >&2
  echo "         identity, or set EDITH_SIGN_IDENTITY, so grants survive reinstalls." >&2
fi

# sign inside-out: the nested helper first, then the outer bundle - never --deep.
codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$HELPER"
codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$APP"

killall Edith 2>/dev/null || true
pkill -if "edith.?menubar" 2>/dev/null || true
if [ "$INSTALL" = 1 ]; then
  rm -rf "/Applications/Edith.app/Contents/Library/LoginItems/Edith"Helper.app
  rm -rf "/Applications/Edith.app" "/Applications/Control Center.app"
  cp -R "$APP" /Applications/
  [ "$NO_OPEN" = 1 ] || open "/Applications/Edith.app"
else
  [ "$NO_OPEN" = 1 ] || open "$APP"
fi
