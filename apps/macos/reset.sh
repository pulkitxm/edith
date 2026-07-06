#!/usr/bin/env bash
#
# reset.sh - remove the installed app and all its local data (settings,
# usage history, music) as if freshly installed. iCloud backup under
# ~/Library/Mobile Documents/com~apple~CloudDocs/Edith is left untouched.
#
#   ./reset.sh        # prompts for confirmation
#   ./reset.sh -y      # skip confirmation
set -euo pipefail

BUNDLE_ID="com.pulkit.edith"
APP_SUPPORT="$HOME/Library/Application Support/Edith"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CACHES="$HOME/Library/Caches/$BUNDLE_ID"
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
INSTALLED_APP="/Applications/Edith.app"

if [ "${1:-}" != "-y" ]; then
  echo "This will delete:"
  echo "  $INSTALLED_APP"
  echo "  $APP_SUPPORT"
  echo "  $PREFS"
  echo "  $CACHES"
  echo "  $SAVED_STATE"
  echo "iCloud backup (~/Library/Mobile Documents/com~apple~CloudDocs/Edith) is kept."
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

killall Edith 2>/dev/null || true
killall EdithMenuBar 2>/dev/null || true

rm -rf "$INSTALLED_APP"
rm -rf "$APP_SUPPORT"
rm -rf "$CACHES"
rm -rf "$SAVED_STATE"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$PREFS"

echo "Done. Reinstall a fresh build/release to test."
