#!/usr/bin/env bash
set -euo pipefail

submissions="${1:?submissions file is required}"
shift
test "$#" -gt 0 || { echo "at least one artifact is required" >&2; exit 1; }
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
: "${NOTARY_KEY:?NOTARY_KEY is required}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$NOTARY_KEY" > "$work/key.p8"
credentials=(--key "$work/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
[ -s "$submissions" ] || echo '{}' > "$submissions"

for artifact in "$@"; do
  attempt=0
  until xcrun notarytool submit "$artifact" --no-wait --output-format json \
    "${credentials[@]}" > "$work/result.json"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 5 ]; then
      echo "notarytool could not upload $artifact after $attempt attempts" >&2
      exit 1
    fi
    sleep $((attempt * ${NOTARY_RETRY_SECONDS:-20}))
  done
  python3 - "$work/result.json" "$submissions" "$artifact" <<'PY'
import json, sys
result, submissions, artifact = sys.argv[1:]
identifier = json.load(open(result))["id"]
recorded = json.load(open(submissions))
recorded[artifact] = identifier
json.dump(recorded, open(submissions, "w"), indent=2)
print(f"submitted {artifact} as {identifier}")
PY
done
