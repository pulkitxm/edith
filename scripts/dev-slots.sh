#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTION=com.pulkit.edith
PREFIX=$PRODUCTION.dev.
LEGACY=$PRODUCTION.development
DEV_DIRECTORY="Edith Dev"
LIBRARY="$HOME/Library"
OWNERS="$LIBRARY/Application Support/$DEV_DIRECTORY/.owners"
DOMAIN="gui/$(id -u)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

usage() {
  cat >&2 <<'USAGE'
usage: scripts/dev-slots.sh slot [PATH] | claim | stop | teardown | gc

  slot      print the development slot name for a worktree path (default: this one)
  claim     record this worktree as the slot's owner and print the slot
  stop      stop this worktree's running development processes
  teardown  stop this worktree's development build and delete its data,
            preferences, keychain items, and permission grants
  gc        tear down slots whose owning worktree is gone, retire the old shared
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

owner_of() {
  cat "$OWNERS/$1" 2>/dev/null || true
}

claim() {
  local root="$1" slot owner
  slot="$(slot_for "$root")"
  owner="$(owner_of "$slot")"
  if [ -n "$owner" ] && [ "$owner" != "$root" ]; then
    if [ -d "$owner" ]; then
      echo "development slot $slot belongs to $owner; rename this worktree folder" >&2
      exit 1
    fi
    teardown_slot "$slot" >&2
  fi
  mkdir -p "$OWNERS"
  printf '%s\n' "$root" >"$OWNERS/$slot"
  printf '%s\n' "$slot"
}

stop_processes() {
  local pattern
  pattern="^$(printf '%s' "$1" | sed 's/[][\\.*^$()+?{}|]/\\&/g')/(dist|build/Build/Products/Debug)/Edith\.app/Contents/"
  pkill -f "$pattern" 2>/dev/null || true
  for _ in $(seq 50); do
    pgrep -f "$pattern" >/dev/null || return 0
    sleep 0.2
  done
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
  local slot="$1" root="${2:-}" identifier="$PREFIX$1" app service
  if [ -n "$root" ]; then
    stop_processes "$root"
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
    "$LIBRARY/Caches/$DEV_DIRECTORY/$slot" "$LIBRARY/Logs/$DEV_DIRECTORY/$slot" "$OWNERS/$slot"
  echo "removed development slot $slot"
}

teardown_here() {
  local root="$1" slot owner
  slot="$(slot_for "$root")"
  owner="$(owner_of "$slot")"
  if [ -n "$owner" ] && [ "$owner" != "$root" ]; then
    echo "development slot $slot belongs to $owner, not this worktree" >&2
    exit 1
  fi
  teardown_slot "$slot" "$root"
}

legacy_running() {
  [ "$(osascript -e "application id \"$LEGACY\" is running" 2>/dev/null)" = true ]
}

gc() {
  local app owner slot
  while IFS= read -r app; do
    case "$app" in /Applications/Edith.app | "$HOME/Applications/Edith.app") continue ;; esac
    "$LSREGISTER" -u "$app" 2>/dev/null || true
    echo "removed $app from LaunchServices"
  done < <("$LSREGISTER" -dump 2>/dev/null | awk -v identifier="$PRODUCTION" '
    /^path:/ { path = $0; sub(/^path: +/, "", path); sub(/ \(0x[0-9a-f]+\)$/, "", path) }
    /^identifier:/ { matched = ($2 == identifier) }
    /^-+$/ { if (matched && path != "") print path; matched = 0; path = "" }')

  for owner in "$OWNERS"/*; do
    [ -f "$owner" ] || continue
    slot="$(basename "$owner")"
    [ -d "$(cat "$owner")" ] || teardown_slot "$slot"
  done

  if legacy_running; then
    echo "kept the shared $LEGACY identity because one of its builds is running"
    return
  fi
  for app in "$LEGACY.agent" "$LEGACY.helper"; do
    launchctl bootout "$DOMAIN/$app" 2>/dev/null || true
    launchctl disable "$DOMAIN/$app" 2>/dev/null || true
  done
  forget_identifiers "$LEGACY" "$LEGACY.helper" "$LEGACY.shared"
  rm -rf "$LIBRARY/Application Support/Edith Development" \
    "$LIBRARY/Caches/Edith Development" "$LIBRARY/Logs/Edith Development"
  echo "retired the shared $LEGACY identity"
}

ROOT="$(pwd -P)"
case "${1:-}" in
  slot) slot_for "${2:-$ROOT}" ;;
  claim) claim "$ROOT" ;;
  stop) stop_processes "$ROOT" ;;
  teardown) teardown_here "$ROOT" ;;
  gc) gc ;;
  *) usage ;;
esac
