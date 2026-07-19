#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="apps/web/.env"
MODE="${1:---missing}"

GENERATED_VARS="LICENSE_KEY_LOOKUP_PEPPER LICENSE_ACCESS_TOKEN_SECRET"

if [ ! -f "$ENV_FILE" ]; then
  cp apps/web/.env.example "$ENV_FILE"
  echo "created $ENV_FILE from .env.example; fill in DATABASE_URL, GITHUB_TOKEN, and LICENSE_SIGNING_PRIVATE_KEY" >&2
fi

current_value() {
  grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-
}

set_value() {
  if grep -q "^$1=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    sed "s|^$1=.*|$1=$2|" "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

if [ "$MODE" = "--rotate" ]; then
  echo "WARNING: rotating LICENSE_KEY_LOOKUP_PEPPER invalidates every stored license digest and refresh credential." >&2
  echo "         Every activated Mac stops verifying and every customer must re-activate with their original key." >&2
  echo "         Customers' local app data is never touched, but treat this as a break-glass operation." >&2
  echo "WARNING: rotating LICENSE_ACCESS_TOKEN_SECRET invalidates outstanding download tokens; clients recover on their next refresh." >&2
  echo "NOTE: LICENSE_SIGNING_PRIVATE_KEY is never rotated by this script; its public key ships inside the app." >&2
  if [ "${2:-}" != "--confirm" ]; then
    echo "env-rotate blocked: run make env-rotate CONFIRM=1 after reading the warnings above" >&2
    exit 1
  fi
  for name in $GENERATED_VARS; do
    set_value "$name" "$(openssl rand -base64 32)"
    echo "rotated $name"
  done
else
  for name in $GENERATED_VARS; do
    if [ -z "$(current_value "$name")" ]; then
      set_value "$name" "$(openssl rand -base64 32)"
      echo "generated $name"
    else
      echo "kept existing $name"
    fi
  done
  if [ -z "$(current_value LICENSE_SIGNING_PRIVATE_KEY)" ]; then
    set_value LICENSE_SIGNING_PRIVATE_KEY "$(openssl rand 32 | base64)"
    echo "generated LICENSE_SIGNING_PRIVATE_KEY"
    echo "NOTE: a new signing key only works with app builds embedding its public key; existing builds trust the old key" >&2
  else
    echo "kept existing LICENSE_SIGNING_PRIVATE_KEY"
  fi
fi

echo "local $ENV_FILE updated; run make env-sync CONFIRM=1 to push and redeploy"
