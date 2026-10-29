#!/usr/bin/env bash
set -euo pipefail

artifact="${1:?artifact to notarize is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
: "${NOTARY_KEY:?NOTARY_KEY is required}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$NOTARY_KEY" > "$work/key.p8"
credentials=(--key "$work/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

xcrun notarytool submit "$artifact" --wait --timeout 45m --output-format json \
  "${credentials[@]}" > "$work/result.json"
status="$(plutil -extract status raw "$work/result.json")"
submission="$(plutil -extract id raw "$work/result.json")"
echo "notarization $submission for $artifact: $status"
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$submission" "${credentials[@]}" >&2 || true
  exit 1
fi

case "$artifact" in
  *.dmg | *.app | *.pkg)
    xcrun stapler staple "$artifact"
    xcrun stapler validate "$artifact"
    ;;
esac
