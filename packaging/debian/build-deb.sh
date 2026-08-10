#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIRECTORY/../.." && pwd)"
PACKAGE_ROOT="$REPOSITORY_ROOT/Packages/Edith"
DEFAULT_VERSION="$(awk '/CFBundleShortVersionString/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}' "$REPOSITORY_ROOT/Resources/Info.plist")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
ARCHITECTURE="${ARCHITECTURE:-$(dpkg --print-architecture)}"
BUILD_ROOT="$REPOSITORY_ROOT/build/linux-deb"
STAGE_ROOT="$BUILD_ROOT/edith_${VERSION}_${ARCHITECTURE}"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$REPOSITORY_ROOT/dist/linux}"

swift build --package-path "$PACKAGE_ROOT" -c release --static-swift-stdlib --product edith-linux
BINARY_DIRECTORY="$(swift build --package-path "$PACKAGE_ROOT" -c release --show-bin-path)"
BINARY="$BINARY_DIRECTORY/edith-linux"

rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT/DEBIAN" "$OUTPUT_DIRECTORY"
install -Dm755 "$BINARY" "$STAGE_ROOT/usr/bin/edith-linux"
STAGED_BINARY="$STAGE_ROOT/usr/bin/edith-linux"
strip --strip-unneeded "$STAGED_BINARY"
install -Dm644 "$REPOSITORY_ROOT/packaging/linux/com.pulkit.Edith.desktop" \
    "$STAGE_ROOT/usr/share/applications/com.pulkit.Edith.desktop"
install -Dm644 "$REPOSITORY_ROOT/packaging/linux/com.pulkit.Edith.metainfo.xml" \
    "$STAGE_ROOT/usr/share/metainfo/com.pulkit.Edith.metainfo.xml"
install -Dm644 "$PACKAGE_ROOT/Sources/Edith/Resources/appicon.png" \
    "$STAGE_ROOT/usr/share/icons/hicolor/512x512/apps/com.pulkit.Edith.png"

DEPENDENCIES="$(
    cd "$REPOSITORY_ROOT/packaging"
    dpkg-shlibdeps -O -e"$STAGED_BINARY" | sed -n 's/^shlibs:Depends=//p'
)"
{
    printf 'Package: edith\n'
    printf 'Version: %s\n' "$VERSION"
    printf 'Section: utils\n'
    printf 'Priority: optional\n'
    printf 'Architecture: %s\n' "$ARCHITECTURE"
    printf 'Maintainer: Pulkit <pulkitxm@users.noreply.github.com>\n'
    printf 'Depends: %s\n' "$DEPENDENCIES"
    printf 'Description: Native control center for Ubuntu\n'
    printf ' Edith combines usage, machines, media, and desktop utilities.\n'
} > "$STAGE_ROOT/DEBIAN/control"

dpkg-deb --root-owner-group --build "$STAGE_ROOT" \
    "$OUTPUT_DIRECTORY/edith_${VERSION}_${ARCHITECTURE}.deb"
