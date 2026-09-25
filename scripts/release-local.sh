#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="pulkitxm/edith"

usage() {
  cat >&2 <<'USAGE'
usage: ./scripts/release-local.sh [--dry-run]

Cuts a release the way CI used to, but entirely on this Mac:
resolve the next version, build and sign the release app, package and verify the
DMG, generate the signed Sparkle appcast, stamp the version files and cask,
commit and tag on main, push, then publish the GitHub release with Pukbot.

  --dry-run        build, sign, package, and verify, but do not commit, tag,
                   push, or publish. Leaves the artifacts under dist/ for review.

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

if [ "$(git branch --show-current)" != main ]; then
  echo "release blocked: run from main" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "release blocked: the working tree is not clean" >&2
  exit 1
fi

WWDR="$(find /Applications/Xcode*.app -iname 'AppleWWDRCA-2030.cer' 2>/dev/null | head -1)"
[ -n "$WWDR" ] || { echo "release blocked: the WWDR G3 intermediate (AppleWWDRCA-2030.cer) is not in Xcode" >&2; exit 1; }

git fetch origin main --tags --quiet

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

cleanup() {
  security list-keychains -d user -s $ORIG_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if [ "$COMMITTED" -eq 0 ]; then
    git checkout -- "${STAGED_FILES[@]}" >/dev/null 2>&1 || true
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
./build.sh --no-open --release
make verify-bundle

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Edith.app/Contents/Info.plist)"
[ "$BUILT" = "$RELEASE_VERSION" ] \
  || { echo "release blocked: built $BUILT, expected $RELEASE_VERSION" >&2; exit 1; }

echo "==> packaging the DMG"
rm -rf dmg-root Edith.dmg && mkdir dmg-root
ditto dist/Edith.app dmg-root/Edith.app
ln -s /Applications dmg-root/Applications
hdiutil create -volname Edith -srcfolder dmg-root -format ULMO Edith.dmg
verify_status=1
for attempt in 1 2 3 4 5; do
  if hdiutil verify Edith.dmg; then verify_status=0; break; fi
  verify_status=$?
  [ "$attempt" -lt 5 ] && sleep 2
done
rm -rf dmg-root
[ "$verify_status" -eq 0 ] || { echo "release blocked: the DMG failed verification" >&2; exit 1; }

echo "==> generating the signed appcast"
GENERATE_APPCAST="$(find build/SourcePackages/artifacts -type f -name generate_appcast -perm -u+x -print -quit)"
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

echo "==> committing, tagging, and pushing"
git commit "${STAGED_FILES[@]}" -m "Release ${RELEASE_TAG}"
git tag -a "$RELEASE_TAG" -m "Edith $RELEASE_TAG build $RELEASE_BUILD"
COMMITTED=1
git push --atomic origin HEAD:main "refs/tags/$RELEASE_TAG"

echo "==> publishing the GitHub release"
pukbot release create "$RELEASE_TAG" --repo "$REPO" --name "Edith $RELEASE_TAG" \
  --target "$(git rev-parse HEAD)" --json
RELEASE_ID="$(gh api "repos/${REPO}/releases/tags/${RELEASE_TAG}" --jq .id)"
[ -n "$RELEASE_ID" ] || { echo "release blocked: could not resolve the release id" >&2; exit 1; }
pukbot release upload-asset "$RELEASE_ID" Edith.dmg --repo "$REPO" --json
pukbot release upload-asset "$RELEASE_ID" dist/appcast/appcast.xml --repo "$REPO" --json

echo "==> released $RELEASE_TAG"
