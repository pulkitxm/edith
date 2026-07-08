#!/usr/bin/env bash
#
# reset.sh - remove the installed app (+ menu bar helper) and all local data
# (settings, usage history, music) as if freshly installed. iCloud backup
# under ~/Library/Mobile Documents/com~apple~CloudDocs/Edith is left
# untouched, and so is the helper's SMAppService login-item registration -
# that's OS-level state, not app data (same as TCC permission grants).
#
#   ./reset.sh        # prompts for confirmation
#   ./reset.sh -y      # skip confirmation
set -euo pipefail

BUNDLE_IDS=("com.pulkit.edith" "com.pulkit.edith.bar" "com.pulkit.edith.menubar" "com.pulkit.edith.shared")
APP_SUPPORT="$HOME/Library/Application Support/Edith"
INSTALLED_APP="/Applications/Edith.app"

if [ "${1:-}" != "-y" ]; then
  echo "This will delete:"
  echo "  $INSTALLED_APP (+ its nested EdithMenuBar.app)"
  echo "  $APP_SUPPORT"
  for id in "${BUNDLE_IDS[@]}"; do
    echo "  ~/Library/Preferences/$id.plist"
    echo "  ~/Library/Caches/$id"
    echo "  ~/Library/HTTPStorages/$id"
    echo "  ~/Library/Saved Application State/$id.savedState"
  done
  echo "iCloud backup (~/Library/Mobile Documents/com~apple~CloudDocs/Edith) is kept."
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

killall Edith 2>/dev/null || true
pkill -if "edith.?menubar" 2>/dev/null || true

rm -rf "$INSTALLED_APP"
rm -rf "$APP_SUPPORT"
for id in "${BUNDLE_IDS[@]}"; do
  defaults delete "$id" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$id.plist"
  rm -rf "$HOME/Library/Caches/$id"
  rm -rf "$HOME/Library/HTTPStorages/$id"
  rm -rf "$HOME/Library/Saved Application State/$id.savedState"
done

echo "Done. Reinstall a fresh build/release to test."
