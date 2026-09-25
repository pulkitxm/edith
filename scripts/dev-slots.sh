#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTION=com.pulkit.edith
PREFIX=$PRODUCTION.dev.
LEGACY=$PRODUCTION.development
DEV_DIRECTORY="Edith Dev"
LIBRARY="$HOME/Library"
DOMAIN="gui/$(id -u)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

usage() {
  cat >&2 <<'USAGE'
usage: scripts/dev-slots.sh slot [PATH] | teardown | gc

  slot      print the development slot for a worktree path (default: this one)
  teardown  stop this worktree's development build and delete its data,
            preferences, and permission grants
  gc        tear down slots whose worktree is gone, retire the old shared
            development identity, and remove production copies outside
            /Applications from LaunchServices
USAGE
  exit 1
}

slot_for() {
  local name
  name="$(basename "$1")"
  name="${name#edith-}"
  [ "$name" != edith ] || name=main
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
  name="${name#-}"
  name="${name%-}"
  printf '%s\n' "${name:-main}"
}

forget_identifiers() {
  local identifier
  for identifier in "$@"; do
    tccutil reset All "$identifier" >/dev/null 2>&1 || true
    defaults delete "$identifier" >/dev/null 2>&1 || true
    rm -f "$LIBRARY/Preferences/$identifier.plist"
    rm -rf "$LIBRARY/Caches/$identifier" "$LIBRARY/HTTPStorages/$identifier" \
      "$LIBRARY/Saved Application State/$identifier.savedState"
  done
}

teardown_slot() {
  local slot="$1" root="${2:-}" identifier="$PREFIX$1" app
  if [ -n "$root" ]; then
    pkill -f "^$root/(dist|build)/.*Edith\.app/Contents/" 2>/dev/null || true
    for app in "$root/dist/Edith.app" "$root/build/Build/Products/Debug/Edith.app"; do
      [ ! -d "$app" ] || "$LSREGISTER" -u "$app" 2>/dev/null || true
    done
  fi
  launchctl bootout "$DOMAIN/$identifier.agent" 2>/dev/null || true
  forget_identifiers "$identifier" "$identifier.helper" "$identifier.shared"
  for service in machines jev companion database; do
    while security delete-generic-password -s "$identifier.$service" >/dev/null 2>&1; do :; done
  done
  rm -rf "$LIBRARY/Application Support/$DEV_DIRECTORY/$slot" \
    "$LIBRARY/Caches/$DEV_DIRECTORY/$slot" "$LIBRARY/Logs/$DEV_DIRECTORY/$slot"
  echo "removed development slot $slot"
}

gc() {
  local worktree app slot label directory
  local -a live=(xcode)
  while IFS= read -r worktree; do
    live+=("$(slot_for "$worktree")")
  done < <(git worktree list --porcelain | sed -n 's/^worktree //p')

  while IFS= read -r app; do
    case "$app" in /Applications/Edith.app | "$HOME/Applications/Edith.app") continue ;; esac
    "$LSREGISTER" -u "$app" 2>/dev/null || true
    echo "removed $app from LaunchServices"
  done < <("$LSREGISTER" -dump 2>/dev/null | awk -v identifier="$PRODUCTION" '
    /^path:/ { path = $0; sub(/^path: +/, "", path); sub(/ \(0x[0-9a-f]+\)$/, "", path) }
    /^identifier:/ { matched = ($2 == identifier) }
    /^-+$/ { if (matched && path != "") print path; matched = 0; path = "" }')

  is_live() {
    local candidate
    for candidate in "${live[@]}"; do [ "$candidate" != "$1" ] || return 0; done
    return 1
  }

  while IFS= read -r label; do
    slot="${label#"$PREFIX"}"
    slot="${slot%.agent}"
    is_live "$slot" || teardown_slot "$slot"
  done < <(launchctl list | awk -v prefix="$PREFIX" 'index($3, prefix) == 1 && $3 ~ /\.agent$/ { print $3 }')

  for directory in "$LIBRARY/Application Support/$DEV_DIRECTORY"/*/; do
    [ -d "$directory" ] || continue
    slot="$(basename "$directory")"
    is_live "$slot" || teardown_slot "$slot"
  done

  for label in "$LEGACY.agent" "$LEGACY.helper"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    launchctl disable "$DOMAIN/$label" 2>/dev/null || true
  done
  forget_identifiers "$LEGACY" "$LEGACY.helper" "$LEGACY.shared"
  rm -rf "$LIBRARY/Application Support/Edith Development" \
    "$LIBRARY/Caches/Edith Development" "$LIBRARY/Logs/Edith Development"
  echo "retired the shared $LEGACY identity"
}

case "${1:-}" in
  slot) slot_for "${2:-$PWD}" ;;
  teardown) teardown_slot "$(slot_for "$PWD")" "$PWD" ;;
  gc) gc ;;
  *) usage ;;
esac
