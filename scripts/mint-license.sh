#!/usr/bin/env bash
set -euo pipefail

MACHINES="${1:?usage: mint-license.sh MACHINES [LABEL] [NAME] [EMAIL] [PHONE]}"
LABEL="${2:-}"
NAME="${3:-}"
EMAIL="${4:-}"
PHONE="${5:-}"

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

sql_text() {
  if [ -n "$1" ]; then
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
  else
    printf "NULL"
  fi
}

LABEL_SQL=$(sql_text "$LABEL")
NAME_SQL=$(sql_text "$NAME")
EMAIL_SQL=$(sql_text "$EMAIL")
PHONE_SQL=$(sql_text "$PHONE")

psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "INSERT INTO licenses (key, key_digest, key_last4, label, name, email, phone, max_machines) VALUES ('$KEY', '$DIGEST', '$LAST4', $LABEL_SQL, $NAME_SQL, $EMAIL_SQL, $PHONE_SQL, $MACHINES);"

echo "license created: $KEY (machines: $MACHINES, label: ${LABEL:-none}, name: ${NAME:-none}, email: ${EMAIL:-none}, phone: ${PHONE:-none})"
