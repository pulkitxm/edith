#!/usr/bin/env bash
set -euo pipefail
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) platform=macos-aarch64 ;;
  Linux/x86_64) platform=linux-x86_64 ;;
  *) echo 'unsupported release-client platform' >&2; exit 1 ;;
esac
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
archive="pukbot-$platform"
curl --fail --silent --show-error --location "https://github.com/pulkitxm/pukbot/releases/download/v0.3.32/$archive" --output "$RUNNER_TEMP/$archive"
curl --fail --silent --show-error --location https://github.com/pulkitxm/pukbot/releases/download/v0.3.32/SHA256SUMS --output "$RUNNER_TEMP/SHA256SUMS"
cd "$RUNNER_TEMP"
shasum -a 256 -c <(rg "  $archive$" SHA256SUMS)
chmod +x "$archive"
mkdir -p bin
mv "$archive" bin/pukbot
printf '%s\n' "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
