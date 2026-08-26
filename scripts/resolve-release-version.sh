#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
REBUILD="${REBUILD:-}"

release_version() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "release blocked: $tag is not a release tag" >&2; return 1; }
  printf '%s\n' "${tag#v}"
}

release_build() {
  local tag="$1" subject version build
  subject="$(git for-each-ref --format='%(contents:subject)' "refs/tags/$tag")"
  if [[ "$subject" =~ ^Edith\ v[0-9]+\.[0-9]+\.[0-9]+\ build\ ([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  read -r version build <<<"$(python3 - <<'PY'
import plistlib
with open("Resources/Info.plist", "rb") as plist:
    info = plistlib.load(plist)
print(info["CFBundleShortVersionString"], info["CFBundleVersion"])
PY
  )"
  [[ "v$version" == "$tag" ]] \
    || { echo "release blocked: $tag has no release build metadata" >&2; return 1; }
  [[ "$build" =~ ^[0-9]+$ ]] \
    || { echo "release blocked: version $version build $build is not numeric" >&2; return 1; }
  printf '%s\n' "$build"
}

latest_release_tag() {
  local tag
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(git tag --merged HEAD --sort=-version:refname)
  return 1
}

if [[ -n "$REBUILD" ]]; then
  git rev-parse "refs/tags/$REBUILD^{commit}" >/dev/null \
    || { echo "release blocked: $REBUILD is not a release tag" >&2; exit 1; }
  VERSION="$(release_version "$REBUILD")"
  BUILD="$(release_build "$REBUILD")"
  {
    echo "tag=$REBUILD"
    echo "version=$VERSION"
    echo "build=$BUILD"
    echo "sha=$(git rev-parse HEAD)"
  } >> "$GITHUB_OUTPUT"
  echo "Rebuilding $REBUILD"
  exit 0
fi

LATEST_TAG="$(latest_release_tag)" \
  || { echo "release blocked: no release tag is available" >&2; exit 1; }
VERSION="$(release_version "$LATEST_TAG")"
BUILD="$(release_build "$LATEST_TAG")"
MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
NEXT="$MAJOR.$MINOR.$((PATCH + 1))"
if git rev-parse "refs/tags/v$NEXT" >/dev/null 2>&1; then
  echo "release blocked: tag v$NEXT already exists" >&2
  exit 1
fi
{
  echo "tag=v$NEXT"
  echo "version=$NEXT"
  echo "build=$((BUILD + 1))"
  echo "sha=$(git rev-parse HEAD)"
} >> "$GITHUB_OUTPUT"
echo "Releasing $VERSION -> $NEXT (build $((BUILD + 1)))"
