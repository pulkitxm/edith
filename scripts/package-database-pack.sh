#!/usr/bin/env bash
set -euo pipefail

binary="${1:?database pack binary is required}"
destination="${2:-.}"

test -f "$binary"
test -x "$binary"
codesign --verify --strict "$binary"

mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$binary" "$staging/edith-database"
chmod 755 "$staging/edith-database"
(
  cd "$staging"
  ditto -c -k --norsrc edith-database "$destination/edith-database.zip"
)
(
  cd "$destination"
  shasum -a 256 edith-database.zip | awk '{print $1 "  edith-database.zip"}' > edith-database.zip.sha256
)
