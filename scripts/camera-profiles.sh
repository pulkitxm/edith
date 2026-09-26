#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

env_file=".env"
[ -f "$env_file" ] || env_file="$(git worktree list --porcelain | head -1 | cut -c10-)/.env"
if [ -f "$env_file" ]; then
  set -a
  . "$env_file"
  set +a
fi
team="${EDITH_TEAM_ID:?set EDITH_TEAM_ID to the team that signs Edith}"
identity="${EDITH_SIGN_IDENTITY:?set EDITH_SIGN_IDENTITY to the Apple Development identity}"
application="${1:-com.pulkit.edith}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

. scripts/signing-keychain.sh
work="$(mktemp -d -t edith-profiles)"
trap 'signing_keychain_close; rm -rf "$work"' EXIT
signing_keychain_open "$identity"

python3 scripts/camera_extension.py project "$work" "$application" "$team" >/dev/null
if ! xcodebuild -project "$work/EdithProfiles.xcodeproj" -alltargets -configuration Debug \
  SYMROOT="$work/build" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >"$work/xcodebuild.log" 2>&1; then
  grep -E 'error:' "$work/xcodebuild.log" | sed 's/^.*error: /error: /' | sort -u >&2
  if grep -q 'Personal development teams' "$work/xcodebuild.log"; then
    echo "Team $team is a free Personal Team. Apple gives the System Extension capability only to paid Apple Developer Program members. Edith can send through OBS Virtual Camera instead." >&2
  fi
  if grep -q 'No Accounts' "$work/xcodebuild.log"; then
    echo "Sign in to Xcode, Settings, Accounts with the Apple ID of team $team, then run make camera-profiles again." >&2
  fi
  exit 1
fi

missing=0
for pair in "$application|com.apple.developer.system-extension.install" "$application.camera|"; do
  identifier="${pair%%|*}"
  entitlement="${pair#*|}"
  found="$(python3 scripts/camera_extension.py find "$identifier" "$team" "$entitlement" "$identity")"
  if [ -n "$found" ]; then
    echo "$identifier: $found"
  else
    echo "$identifier: no usable profile was created" >&2
    missing=1
  fi
done
[ "$missing" = 0 ] || exit 1
echo "profiles ready; run make install, then install Edith Camera from the Virtual Camera page"
