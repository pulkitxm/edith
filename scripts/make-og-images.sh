#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
test -x "$CHROME" || {
  echo "og images blocked: Chrome not found at $CHROME (override with CHROME=...)" >&2
  exit 1
}

for page in home privacy terms; do
  out="apps/site/og-${page}.png"
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --allow-file-access-from-files \
    --force-color-profile=srgb \
    --window-size=1200,630 \
    --screenshot="$out" \
    --virtual-time-budget=3000 \
    "file://$PWD/scripts/og/${page}.html" >/dev/null 2>&1
  test -s "$out" || { echo "og images blocked: $out was not written" >&2; exit 1; }
  echo "wrote $out"
done
