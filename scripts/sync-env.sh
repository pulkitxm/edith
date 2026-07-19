#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="apps/web/.env"
TARGET="${2:-production}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env-sync blocked: $ENV_FILE does not exist" >&2
  exit 1
fi

echo "WARNING: this replaces every Vercel $TARGET environment variable with the values in $ENV_FILE." >&2
echo "WARNING: rotating LICENSE_KEY_LOOKUP_PEPPER invalidates every stored license digest and refresh credential;" >&2
echo "         every activated Mac will fail verification and every customer must re-activate with their original key." >&2
echo "WARNING: rotating LICENSE_SIGNING_PRIVATE_KEY breaks entitlement verification in every shipped build." >&2
echo "WARNING: changing DATABASE_URL points the licensing service at a different database." >&2
echo "         Customers' local app data is never touched, but their licenses stop verifying until re-activation." >&2

if [ "${1:-}" != "--confirm" ]; then
  echo "env-sync blocked: run with CONFIRM=1 (make env-sync CONFIRM=1) after reading the warnings above" >&2
  exit 1
fi

while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  name="${line%%=*}"
  value="${line#*=}"
  if [ -z "$name" ] || [ -z "$value" ]; then
    continue
  fi
  npx -y vercel env rm "$name" "$TARGET" --cwd apps/web --yes >/dev/null 2>&1 || true
  printf '%s' "$value" | npx -y vercel env add "$name" "$TARGET" --cwd apps/web >/dev/null
  echo "synced $name"
done < "$ENV_FILE"

echo "deploying $TARGET with the refreshed environment"
npx -y vercel deploy --prod --cwd apps/web
