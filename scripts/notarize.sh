#!/usr/bin/env bash
set -euo pipefail

artifact="${1:?artifact to notarize is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
: "${NOTARY_KEY:?NOTARY_KEY is required}"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$here/notary-submit.sh" "$work/submissions.json" "$artifact"
python3 "$here/notary_wait.py" "$work/submissions.json"

case "$artifact" in
  *.dmg | *.app | *.pkg)
    xcrun stapler staple "$artifact"
    xcrun stapler validate "$artifact"
    ;;
esac
