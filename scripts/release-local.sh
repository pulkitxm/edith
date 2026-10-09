#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="pulkitxm/edith"

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/release-local.sh [--dry-run]

Builds and publishes an empty-host release on this Mac:
resolve the next version, build and sign the release app, package and verify the
DMG, generate the signed Sparkle appcast, stamp the version files and cask,
commit and tag through Pukbot, then publish the verified host assets.

  --dry-run        build, sign, package, and verify, but do not commit, tag,
                   or publish. Leaves the artifacts under dist/ for review.

Signing material is read from .env at the repository root. See AGENTS.md.
USAGE
  exit 1
}

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

set -a
[ -f .env ] || { echo "release blocked: .env is missing (see AGENTS.md)" >&2; exit 1; }
. ./.env
set +a

: "${MACOS_CERT_P12_BASE64:?release blocked: MACOS_CERT_P12_BASE64 missing from .env}"
: "${MACOS_CERT_PASSWORD:?release blocked: MACOS_CERT_PASSWORD missing from .env}"
: "${SPARKLE_PRIVATE_KEY:?release blocked: SPARKLE_PRIVATE_KEY missing from .env}"
: "${EDITH_SIGN_IDENTITY:?release blocked: EDITH_SIGN_IDENTITY missing from .env}"
export EDITH_RELEASE_ALLOW_DEV_SIGNING="${EDITH_RELEASE_ALLOW_DEV_SIGNING:-1}"

if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$(git branch --show-current)" != main ]; then
    echo "release blocked: run from main" >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "release blocked: the working tree is not clean" >&2
    exit 1
  fi
fi

WWDR="$(find /Applications/Xcode*.app -iname 'AppleWWDRCA-2030.cer' 2>/dev/null | head -1)"
[ -n "$WWDR" ] || { echo "release blocked: the WWDR G3 intermediate (AppleWWDRCA-2030.cer) is not in Xcode" >&2; exit 1; }

git fetch origin main --tags --quiet
BUILT_SHA="$(git rev-parse HEAD)"
export BUILT_SHA

TMP_OUT="$(mktemp)"
GITHUB_OUTPUT="$TMP_OUT" ./scripts/resolve-release-version.sh
RELEASE_TAG="$(sed -n 's/^tag=//p' "$TMP_OUT")"
RELEASE_VERSION="$(sed -n 's/^version=//p' "$TMP_OUT")"
RELEASE_BUILD="$(sed -n 's/^build=//p' "$TMP_OUT")"
rm -f "$TMP_OUT"
[ -n "$RELEASE_TAG" ] && [ -n "$RELEASE_VERSION" ] && [ -n "$RELEASE_BUILD" ] \
  || { echo "release blocked: could not resolve the next version" >&2; exit 1; }
echo "==> releasing $RELEASE_TAG (version $RELEASE_VERSION, build $RELEASE_BUILD)"

KEYCHAIN="$HOME/Library/Keychains/edith-release-$$.keychain-db"
ORIG_KEYCHAINS="$(security list-keychains -d user | sed 's/[",]//g' | xargs)"
STAGED_FILES=(Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb)
COMMITTED=0
RELEASE_PLISTS_DIR="$(mktemp -d)"
SUPERSEDED_FILE="$RELEASE_PLISTS_DIR/superseded"

cleanup() {
  security list-keychains -d user -s $ORIG_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$RELEASE_PLISTS_DIR"
  if [ "$COMMITTED" -eq 0 ]; then
    git checkout HEAD -- "${STAGED_FILES[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

security create-keychain -p release "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p release "$KEYCHAIN"
security import "$WWDR" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null 2>&1
P12="$(mktemp).p12"
printf '%s' "$MACOS_CERT_P12_BASE64" | base64 -d > "$P12"
security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null 2>&1
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple: -s -k release "$KEYCHAIN" >/dev/null 2>&1
security list-keychains -d user -s "$KEYCHAIN" $ORIG_KEYCHAINS >/dev/null
security find-identity -v -p codesigning | grep -qF "$EDITH_SIGN_IDENTITY" \
  || { echo "release blocked: $EDITH_SIGN_IDENTITY is not a valid signing identity" >&2; exit 1; }

for plist in Resources/Info.plist Resources/HelperInfo.plist; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$plist"
done

echo "==> building the release app"
if [ "$DRY_RUN" -eq 1 ]; then
  ./build.sh --no-open --release
else
  RELEASE_SUPERSEDED_FILE="$SUPERSEDED_FILE" ./scripts/run-current-release-build.sh ./build.sh --no-open --release
fi
make verify-bundle

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Edith.app/Contents/Info.plist)"
[ "$BUILT" = "$RELEASE_VERSION" ] \
  || { echo "release blocked: built $BUILT, expected $RELEASE_VERSION" >&2; exit 1; }

echo "==> packaging the empty-host DMG"
python3 scripts/package-host-dmg.py dist/Edith.app Edith.dmg

echo "==> generating the signed appcast"
GENERATE_APPCAST="$(find Packages/EdithHost/.build/artifacts -type f -name generate_appcast -perm -u+x -print -quit)"
[ -n "$GENERATE_APPCAST" ] || { echo "release blocked: generate_appcast is missing" >&2; exit 1; }
rm -rf dist/appcast && mkdir dist/appcast
cp Edith.dmg dist/appcast/
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${RELEASE_TAG}/" \
  dist/appcast
[ -f dist/appcast/appcast.xml ] || mv dist/appcast/appcast dist/appcast/appcast.xml
grep -q "url=\"https://github.com/${REPO}/releases/download/${RELEASE_TAG}/Edith.dmg\"" dist/appcast/appcast.xml \
  || { echo "release blocked: the appcast points at the wrong DMG" >&2; exit 1; }
grep -q 'sparkle:edSignature=' dist/appcast/appcast.xml \
  || { echo "release blocked: the appcast is not signed" >&2; exit 1; }

echo "==> rewriting the cask"
RELEASE_SHA256="$(shasum -a 256 Edith.dmg | cut -d' ' -f1)"
sed \
  -e "s/^  version \".*\"$/  version \"$RELEASE_VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$RELEASE_SHA256\"/" \
  Casks/edith.rb > Casks/edith.rb.next
mv Casks/edith.rb.next Casks/edith.rb
grep -qx "  version \"$RELEASE_VERSION\"" Casks/edith.rb \
  && grep -qx "  sha256 \"$RELEASE_SHA256\"" Casks/edith.rb \
  || { echo "release blocked: the cask rewrite did not take" >&2; exit 1; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> dry run complete: dist/Edith.app, Edith.dmg, and dist/appcast/appcast.xml are ready"
  echo "    version files and cask are staged in the working tree and will be reverted on exit"
  exit 0
fi

node scripts/extension-release-ready.mjs .
pukbot capabilities --json
pukbot commit create --help
pukbot tag create --help
pukbot release create --help
pukbot release upload-asset --help

export RELEASE_TAG RELEASE_VERSION RELEASE_BUILD RELEASE_SHA256 RELEASE_PLISTS_DIR
mkdir -p dist/host-release-assets
cp Edith.dmg dist/host-release-assets/
cp dist/appcast/appcast.xml dist/host-release-assets/
GITHUB_REPOSITORY="$REPO" node scripts/publish-host-release.mjs --preflight dist/host-release-assets

echo "==> committing and tagging the verified release"
cp Resources/Info.plist Resources/HelperInfo.plist "$RELEASE_PLISTS_DIR/"
export RELEASE_TAG RELEASE_VERSION RELEASE_BUILD RELEASE_SHA256 RELEASE_PLISTS_DIR
GITHUB_REPOSITORY="$REPO" bash scripts/publish-release-state.sh cut
COMMITTED=1
RELEASE_TARGET_SHA="$(git rev-parse HEAD)"
echo "==> publishing the host release"
GITHUB_REPOSITORY="$REPO" RELEASE_TARGET_SHA="$RELEASE_TARGET_SHA" \
  node scripts/publish-host-release.mjs dist/host-release-assets
git switch main
echo "==> released $RELEASE_TAG"
