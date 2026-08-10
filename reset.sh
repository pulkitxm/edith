#!/usr/bin/env bash
#
# reset.sh - completely remove Edith from this Mac: the installed app (+ nested
# menu bar helper), all local data (settings, usage history, clipboard, music),
# preferences, caches, saved state, the SMAppService login-item registrations,
# and every TCC permission grant. The ONLY thing left untouched is the iCloud
# backup under ~/Library/Mobile Documents/com~apple~CloudDocs/Edith, so a fresh
# install can restore from it.
#
#   ./reset.sh        # prompts for confirmation
#   ./reset.sh -y      # skip confirmation
set -uo pipefail

BUNDLE_IDS=("com.pulkit.edith" "com.pulkit.edith.statusbar" "com.pulkit.edith.panel" "com.pulkit.edith.bar" "com.pulkit.edith.menubar" "com.pulkit.edith.shared")
HELPER_IDS=("com.pulkit.edith.statusbar" "com.pulkit.edith.panel" "com.pulkit.edith.bar" "com.pulkit.edith.menubar")
APP_SUPPORT="$HOME/Library/Application Support/Edith"
INSTALLED_APPS=("/Applications/Edith.app" "$HOME/Applications/Edith.app")
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Edith"
UID_NUM="$(id -u)"

if [ "${1:-}" != "-y" ]; then
  echo "This will permanently delete Edith from this Mac:"
  for app in "${INSTALLED_APPS[@]}"; do echo "  $app"; done
  echo "  $APP_SUPPORT (settings, usage history, clipboard, music)"
  for id in "${BUNDLE_IDS[@]}"; do
    echo "  preferences / caches / saved state for $id"
  done
  echo "  SMAppService login items: ${HELPER_IDS[*]}"
  echo "  all TCC permission grants (Calendar, Screen Recording, Accessibility, ...)"
  echo
  echo "KEPT: iCloud backup at $ICLOUD_DIR"
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

# 1. quit anything running
killall Edith 2>/dev/null || true
pkill -x EdithHelper 2>/dev/null || true
pkill -f "/Applications/Edith.app" 2>/dev/null || true
sleep 1

# 2. tear down the login-item registrations so nothing relaunches at login
for id in "${HELPER_IDS[@]}"; do
  launchctl bootout "gui/$UID_NUM/$id" 2>/dev/null || true
  launchctl disable "gui/$UID_NUM/$id" 2>/dev/null || true
done

# 3. revoke every TCC permission grant
for id in "${BUNDLE_IDS[@]}"; do
  tccutil reset All "$id" 2>/dev/null || true
done

# 4. remove the app bundles and deregister them from LaunchServices
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
for app in "${INSTALLED_APPS[@]}"; do
  [ -e "$app" ] && "$LSREGISTER" -u "$app" 2>/dev/null || true
  rm -rf "$app"
done

# 5. remove local data (App Support). iCloud backup is deliberately left alone.
rm -rf "$APP_SUPPORT"

# 6. remove preferences, caches, saved state and containers for every bundle id
for id in "${BUNDLE_IDS[@]}"; do
  defaults delete "$id" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$id.plist"
  rm -f "$HOME/Library/Preferences/ByHost/$id".*.plist 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/$id"
  rm -rf "$HOME/Library/HTTPStorages/$id"
  rm -rf "$HOME/Library/Saved Application State/$id.savedState"
  rm -rf "$HOME/Library/Containers/$id"
  rm -rf "$HOME/Library/Group Containers/$id"
done

# 7. flush the preferences cache so nothing lingers in memory
killall cfprefsd 2>/dev/null || true

echo "Done. Edith has been fully removed. iCloud backup kept at:"
echo "  $ICLOUD_DIR"
