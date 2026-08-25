#!/usr/bin/env bash
set -euo pipefail

HEAD_REF="${RELEASE_ARTIFACT_HEAD_REF:-HEAD}"
SHIPPED_PATTERN='^(Packages/Edith/(Package\.(swift|resolved)|Sources/|Vendor/)|Resources/|edth\.xcodeproj/|build\.sh$)'

inspection_failed() {
  echo "release artifact inspection failed: $1" >&2
  exit 2
}

HEAD_SHA="$(git rev-parse --verify "${HEAD_REF}^{commit}")" \
  || inspection_failed "could not resolve $HEAD_REF"
SHALLOW="$(git rev-parse --is-shallow-repository)" \
  || inspection_failed "could not inspect repository depth"
[[ "$SHALLOW" == false ]] || inspection_failed "repository is shallow"
TAGS="$(git tag --merged "$HEAD_SHA" --sort=-version:refname)" \
  || inspection_failed "could not list release tags"
LATEST_TAG=""
while IFS= read -r tag; do
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    LATEST_TAG="$tag"
    break
  fi
done <<< "$TAGS"
[[ -n "$LATEST_TAG" ]] || inspection_failed "no release tag is available"
CHANGED="$(git diff --no-renames --name-only "$LATEST_TAG" "$HEAD_SHA")" \
  || inspection_failed "could not compare $LATEST_TAG with $HEAD_REF"
echo "release artifact comparison: $LATEST_TAG..$HEAD_REF" >&2

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" =~ $SHIPPED_PATTERN ]]; then
    echo "release artifact changed: $path" >&2
    exit 0
  fi
done <<< "$CHANGED"

echo "release artifact unchanged" >&2
exit 1
