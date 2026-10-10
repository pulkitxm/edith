#!/usr/bin/env bash
set -euo pipefail

GHOSTTY_COMMIT="88f57ee66eeaad4da77b414b245f7b6693348985"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
ZIG_VERSION="0.16.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/vendor"
src="$vendor/ghostty"
out="$root/Packages/Edith/vendor/GhosttyKit.xcframework"
resources_out="$root/Packages/Edith/vendor/GhosttyResources"
extension_vendor="$root/Extensions/terminal/Native/vendor"
patch="$root/scripts/patches/ghostty-external-io.patch"
run_tests=false
if [ "${1:-}" = "--test-external-io" ]; then
  run_tests=true
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--test-external-io]" >&2
  exit 1
fi

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

if git -C "$src" apply --reverse --check "$patch" 2>/dev/null; then
  :
else
  git -C "$src" apply --check "$patch"
  git -C "$src" apply "$patch"
fi

built="$src/macos/GhosttyKit.xcframework"
rm -rf "$built"

(
  cd "$src"
  "$zig_bin" build -j1 \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast
)

if [ ! -d "$built" ]; then
  echo "xcframework was not produced at $built" >&2
  exit 1
fi

shell_integration="$src/zig-out/share/ghostty/shell-integration"
terminfo="$src/zig-out/share/terminfo"
if [ ! -f "$shell_integration/zsh/ghostty-integration" ] \
  || [ ! -f "$terminfo/78/xterm-ghostty" ]; then
  echo "Ghostty resources were not produced by the pinned build" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
rm -rf "$out"
cp -R "$built" "$out"

lib="$(find "$out" -name 'libghostty-*.a' | head -1)"
symbols="$(nm -g "$lib" 2>/dev/null | grep -c -E ' T _ghostty_(config_new|surface_external_output|surface_external_set_termios|surface_external_exit)$' || true)"
if [ "$symbols" != "4" ]; then
  echo "built archive is missing the libghostty API" >&2
  exit 1
fi

if [ "$run_tests" = true ]; then
  test_binary="$src/.zig-cache/edith-external-io-test"
  xcrun clang -fobjc-arc -mmacosx-version-min=14.0 \
    -I "$src/include" "$src/tests/external_io.m" "$lib" \
    -framework AppKit -framework Carbon -framework Metal -framework QuartzCore \
    -framework IOSurface -framework CoreText -lc++ -o "$test_binary"
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-external-io.XXXXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  env HOME="$fixture" XDG_CONFIG_HOME="$fixture/config" \
    XDG_CACHE_HOME="$fixture/cache" GHOSTTY_RESOURCES_DIR="$src/zig-out/share/ghostty" \
    "$test_binary"
fi

rm -rf "$resources_out"
mkdir -p "$resources_out/ghostty"
cp -R "$shell_integration" "$resources_out/ghostty/shell-integration"
cp -R "$terminfo" "$resources_out/terminfo"

rm -rf "$extension_vendor"
mkdir -p "$extension_vendor"
cp -R "$out" "$extension_vendor/GhosttyKit.xcframework"
cp -R "$resources_out" "$extension_vendor/GhosttyResources"

echo "GhosttyKit.xcframework ready at $out and $extension_vendor with resources at $resources_out"
