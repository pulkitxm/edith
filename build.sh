#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat >&2 <<'USAGE'
usage: ./build.sh [--install] [--no-open] [--release] [--pr N | --branch NAME]

  --install      copy to /Applications and launch from there
  --no-open      build only, do not launch
  --release      Release configuration, Developer ID signing required
  --pr N         build PR N's branch from its worktree, creating one if needed
  --branch NAME  same, for a branch named directly

Signing identity is EDITH_SIGN_IDENTITY, else the first available Developer ID
Application, "Edith Dev", or Apple Development certificate, else ad-hoc.
See CONTRIBUTING.md for why the designated requirement is pinned to the team id.
USAGE
  exit 1
}

resolve_developer_dir() {
  local candidate
  candidate="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
  if [ -x "$candidate/usr/bin/xcodebuild" ]; then echo "$candidate"; return; fi
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    if [ -x "$candidate/usr/bin/xcodebuild" ]; then echo "$candidate"; return; fi
  done
}

DEVELOPER_DIR="$(resolve_developer_dir)"
if [ -z "$DEVELOPER_DIR" ]; then
  echo "Xcode is required to build edth.xcodeproj, Command Line Tools alone cannot." >&2
  echo "Install Xcode, or point at it with xcode-select -s or DEVELOPER_DIR." >&2
  exit 1
fi
export DEVELOPER_DIR

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}

team_id_for() {
  security find-certificate -c "$1" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([^,/]*\).*/\1/p'
}

INSTALL=0 NO_OPEN=0 PR="" BRANCH="" RELEASE="${EDITH_RELEASE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --no-open) NO_OPEN=1 ;;
    --release) RELEASE=1 ;;
    --pr) PR="${2:?--pr needs a PR number}"; shift ;;
    --branch) BRANCH="${2:?--branch needs a branch name}"; shift ;;
    *) usage ;;
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
    exec "$ROOT/build.sh" --install
  fi
fi

CONFIG=Debug
[ "$RELEASE" = 1 ] && CONFIG=Release

TEAM_ID=""
[ "$SIGN_IDENTITY" = "-" ] || TEAM_ID="$(team_id_for "$SIGN_IDENTITY" || true)"

DERIVED=build
xcodebuild -project edth.xcodeproj -scheme EdithMain -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -quiet \
  -onlyUsePackageVersionsFromResolvedFile \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build

BUILT="$DERIVED/Build/Products/$CONFIG/Edith.app"
test -d "$BUILT" || { echo "build did not produce $BUILT" >&2; exit 1; }

APP="dist/Edith.app"
HELPER="$APP/Contents/Library/LoginItems/Edith.app"
FILES_APP="$APP/Contents/Library/Applications/Edith Files.app"
rm -rf dist && mkdir -p dist
ditto "$BUILT" "$APP"

rm -rf "$FILES_APP/Contents/Frameworks"

if [ "$RELEASE" = 1 ]; then
  find "$APP" -type f -perm -u+x -print0 \
    | while IFS= read -r -d '' binary; do
        case "$(file -b "$binary")" in
          *Mach-O*) strip -rSTx "$binary" 2>/dev/null || true ;;
        esac
      done
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "WARNING: no signing identity found; signing ad-hoc. The code signature" >&2
  echo "         changes every build, so macOS TCC permission grants (Screen" >&2
  echo "         Recording, Accessibility, Calendar, ...) reset on every reinstall." >&2
  echo "         Use a Developer ID / Apple Development / self-signed 'Edith Dev'" >&2
  echo "         identity, or set EDITH_SIGN_IDENTITY, so grants survive reinstalls." >&2
fi

sign() {
  local identifier
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")"
  if [ -n "$TEAM_ID" ]; then
    codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS --requirements \
      "=designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
      "$1"
  else
    codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$1"
  fi
}

sign_tool() {
  codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$1"
}

sign_tool "$APP/Contents/MacOS/ed"
sign_tool "$APP/Contents/MacOS/edh"
sign "$HELPER"
sign "$FILES_APP"
sign "$APP"

killall Edith 2>/dev/null || true
pkill -x EdithHelper 2>/dev/null || true
sleep 1

if [ "$INSTALL" = 1 ]; then
  rm -rf "/Applications/Edith.app"
  cp -R "$APP" /Applications/
  [ "$NO_OPEN" = 1 ] || open "/Applications/Edith.app"
else
  [ "$NO_OPEN" = 1 ] || open "$APP"
fi
