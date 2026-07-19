#!/usr/bin/env bash
set -euo pipefail

MACHINES="${1:?usage: mint-license.sh MACHINES [LABEL]}"
LABEL="${2:-}"

case "$MACHINES" in
  ''|*[!0-9]*)
    echo "mint-license blocked: MACHINES must be a positive integer" >&2
    exit 1
    ;;
esac

DB_URL=$(grep '^DATABASE_URL=' apps/web/.env | cut -d= -f2- | tr -d '"' | sed 's/&channel_binding=[^&]*//;s/channel_binding=[^&]*&//')
test -n "$DB_URL" || { echo "mint-license blocked: DATABASE_URL missing from apps/web/.env" >&2; exit 1; }

KEY_PARTS=$(cd apps/web && bun -e '
const { generateLicenseKey, keyLookupDigest, displaySuffix } = await import("./lib/license-key.ts");
const key = generateLicenseKey();
console.log([key, keyLookupDigest(key), displaySuffix(key)].join(" "));')

KEY=$(echo "$KEY_PARTS" | awk "{print \$1}")
DIGEST=$(echo "$KEY_PARTS" | awk "{print \$2}")
LAST4=$(echo "$KEY_PARTS" | awk "{print \$3}")

if [ -n "$LABEL" ]; then
  LABEL_SQL="'$(printf '%s' "$LABEL" | sed "s/'/''/g")'"
else
  LABEL_SQL="NULL"
fi

psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "INSERT INTO licenses (key, key_digest, key_last4, label, max_machines) VALUES ('$KEY', '$DIGEST', '$LAST4', $LABEL_SQL, $MACHINES);"

echo "license created: $KEY (machines: $MACHINES, label: ${LABEL:-none})"
