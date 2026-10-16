zig_version="0.16.0"
zig_sha256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
zig_dir="${RUNNER_TOOL_CACHE:-$HOME/.cache}/zig-$zig_version"
if [ ! -x "$zig_dir/zig" ]; then
  zig_archive="${RUNNER_TEMP:-/tmp}/zig-$zig_version.tar.xz"
  curl -fsSL --retry 3 -o "$zig_archive" \
    "https://ziglang.org/download/$zig_version/zig-aarch64-macos-$zig_version.tar.xz"
  echo "$zig_sha256  $zig_archive" | shasum -a 256 -c - >/dev/null
  mkdir -p "$zig_dir"
  tar -xJf "$zig_archive" -C "$zig_dir" --strip-components 1
fi
export PATH="$zig_dir:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$zig_dir" >> "$GITHUB_PATH"; fi
test "$(zig version)" = "$zig_version"
