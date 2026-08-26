#!/usr/bin/env bash
set -euo pipefail

GHOSTTY_COMMIT="88f57ee66eeaad4da77b414b245f7b6693348985"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
ZIG_VERSION="0.16.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/vendor"
src="$vendor/ghostty"
out="$root/Packages/Edith/vendor/GhosttyKit.xcframework"

zig_bin="$(command -v zig || true)"
if [ -n "$zig_bin" ] && [ "$("$zig_bin" version)" = "$ZIG_VERSION" ]; then
  :
elif [ -x "/opt/homebrew/Cellar/zig/${ZIG_VERSION}_1/bin/zig" ]; then
  zig_bin="/opt/homebrew/Cellar/zig/${ZIG_VERSION}_1/bin/zig"
else
  zig_bin="$(ls -d /opt/homebrew/Cellar/zig/${ZIG_VERSION}*/bin/zig 2>/dev/null | head -1 || true)"
fi

if [ -z "$zig_bin" ] || [ ! -x "$zig_bin" ]; then
  echo "zig $ZIG_VERSION is required: brew install zig" >&2
  exit 1
fi

have="$("$zig_bin" version)"
if [ "$have" != "$ZIG_VERSION" ]; then
  echo "zig $ZIG_VERSION is required, found $have" >&2
  exit 1
fi

mkdir -p "$vendor"
if [ ! -d "$src/.git" ]; then
  git clone --filter=blob:none "$GHOSTTY_REPO" "$src"
fi

git -C "$src" fetch --depth 1 origin "$GHOSTTY_COMMIT"
git -C "$src" checkout --detach "$GHOSTTY_COMMIT"

(
  cd "$src"
  "$zig_bin" build \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast \
    || true
)

built="$src/macos/GhosttyKit.xcframework"
if [ ! -d "$built" ]; then
  echo "xcframework was not produced at $built" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
rm -rf "$out"
cp -R "$built" "$out"

lib="$(find "$out" -name 'libghostty-*.a' | head -1)"
symbols="$(nm -g "$lib" 2>/dev/null | grep -c ' T _ghostty_config_new$' || true)"
if [ "$symbols" != "1" ]; then
  echo "built archive is missing the libghostty API" >&2
  exit 1
fi

echo "GhosttyKit.xcframework ready at $out"
