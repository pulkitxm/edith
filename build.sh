#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat >&2 <<'USAGE'
usage: ./build.sh [--install] [--no-open] [--background] [--release] [--pr N | --branch NAME]
       ./build.sh --release --install --from-app PATH [--no-open]
       ./build.sh --teardown | --gc

  --install      copy a Release build to /Applications and launch from there
  --no-open      build only, do not launch
  --background   build without focusing, then launch the development app hidden
  --release      Release configuration, Developer ID signing required
  --from-app     install an existing production-signed bundle without rebuilding
  --pr N         build PR N's branch from its worktree, creating one if needed
  --branch NAME  same, for a branch named directly
  --teardown     stop this worktree's development build and delete its data
  --gc           clean up development slots whose worktree is gone

A development build runs as its own app, "Edith (<slot>)", where the slot comes
from the worktree folder name. Only /Applications/Edith.app runs as Edith.

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
  echo "Xcode is required to build the host, Command Line Tools alone cannot." >&2
  echo "Install Xcode, or point at it with xcode-select -s or DEVELOPER_DIR." >&2
  exit 1
fi
export DEVELOPER_DIR

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}

INSTALL=0 NO_OPEN=0 BACKGROUND=0 PR="" BRANCH="" RELEASE="${EDITH_RELEASE:-0}"
PREBUILT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --no-open) NO_OPEN=1 ;;
    --background) BACKGROUND=1 ;;
    --release) RELEASE=1 ;;
    --from-app) PREBUILT="${2:?--from-app needs an application path}"; shift ;;
    --pr) PR="${2:?--pr needs a PR number}"; shift ;;
    --branch) BRANCH="${2:?--branch needs a branch name}"; shift ;;
    --teardown) exec scripts/dev-slots.sh teardown ;;
    --gc) exec scripts/dev-slots.sh gc ;;
    *) usage ;;
  esac
  shift
done

if [ "$INSTALL" = 1 ] && [ "$RELEASE" != 1 ]; then
  echo "Development builds cannot replace /Applications/Edith.app. Use --release --install, or launch dist/Edith.app." >&2
  exit 1
fi

if [ -n "$PREBUILT" ]; then
  if [ "$INSTALL" != 1 ] || [ "$RELEASE" != 1 ] || [ -n "$PR$BRANCH" ]; then
    echo "--from-app requires --release --install without --pr or --branch." >&2
    exit 1
  fi
  REQUIREMENT='anchor apple generic and identifier "com.pulkit.edith" and certificate leaf[subject.OU] = "HDYBQ2SLGT"'
  if [ "${EDITH_RELEASE_ALLOW_DEV_SIGNING:-0}" != 1 ]; then
    REQUIREMENT+=' and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  fi
  codesign --verify --deep --strict --test-requirement "=$REQUIREMENT" "$PREBUILT"
  python3 scripts/verify-shipping-host.py "$PREBUILT" --release
  python3 scripts/install_app.py "$PREBUILT" "/Applications/Edith.app"
  if [ "$NO_OPEN" != 1 ]; then open -n "/Applications/Edith.app"; fi
  exit 0
fi

if [ "$INSTALL" = 1 ]; then
  env_file=".env"
  [ -f "$env_file" ] || env_file="$(git worktree list --porcelain | head -1 | cut -c10-)/.env"
  if [ -f "$env_file" ]; then
    set -a
    . "$env_file"
    set +a
  fi
fi

if [ "$RELEASE" = 1 ]; then
  SIGN_IDENTITY="${EDITH_SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  case "$SIGN_IDENTITY" in
    *"Developer ID Application"*)
      :
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
    BUILD_ARGUMENTS=()
    [ "$INSTALL" = 0 ] || BUILD_ARGUMENTS+=(--install)
    [ "$NO_OPEN" = 0 ] || BUILD_ARGUMENTS+=(--no-open)
    [ "$BACKGROUND" = 0 ] || BUILD_ARGUMENTS+=(--background)
    [ "$RELEASE" = 0 ] || BUILD_ARGUMENTS+=(--release)
    exec "$ROOT/build.sh" "${BUILD_ARGUMENTS[@]}"
  fi
fi

if [ "$INSTALL" = 1 ] && [ -n "${EDITH_SIGN_IDENTITY:-}" ]; then
  . scripts/signing-keychain.sh
  trap signing_keychain_close EXIT
  signing_keychain_open "$SIGN_IDENTITY"
fi

SLOT=""
if [ "$RELEASE" != 1 ]; then
  SLOT="$(scripts/dev-slots.sh claim)"
  echo "development slot $SLOT (com.pulkit.edith.dev.$SLOT)"
fi

node scripts/build-minimal-host.mjs
python3 scripts/package-shipping-host.py local/minimal-host/Edith.app dist/Edith.app \
  --identity "$SIGN_IDENTITY" ${SLOT:+--slot "$SLOT"} \
  $([ "$RELEASE" != 1 ] || printf '%s' '--release')
APP="dist/Edith.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [ "$RELEASE" = 1 ]; then
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
fi

if [ "$INSTALL" = 1 ]; then
  python3 scripts/install_app.py "$APP" "/Applications/Edith.app"
  [ "$NO_OPEN" = 1 ] || open -n "/Applications/Edith.app"
elif [ "$RELEASE" = 1 ]; then
  echo "built $APP; Edith only runs from /Applications, install it with --release --install"
elif [ "$BACKGROUND" = 1 ]; then
  scripts/dev-slots.sh stop
  open -g -j -F --env EDITH_BACKGROUND_TESTING=1 "$APP"
elif [ "$NO_OPEN" != 1 ]; then
  scripts/dev-slots.sh stop
  open "$APP"
fi
