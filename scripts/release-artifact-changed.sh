#!/usr/bin/env bash
set -euo pipefail

HEAD_REF="${RELEASE_ARTIFACT_HEAD_REF:-HEAD}"
SHIPPED_PATTERN='^(Packages/Edith/(Package\.(swift|resolved)|Sources/|Vendor/)|Resources/|edth\.xcodeproj/|build\.sh$)'

git rev-parse "${HEAD_REF}^{commit}" >/dev/null
LATEST_TAG="$({
  git tag --merged "$HEAD_REF" --sort=-version:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n 1
} || true)"

if [[ -n "$LATEST_TAG" ]]; then
  CHANGED="$(git diff --name-only "$LATEST_TAG" "$HEAD_REF")"
  echo "release artifact comparison: $LATEST_TAG..$HEAD_REF" >&2
else
  CHANGED="$(git ls-tree -r --name-only "$HEAD_REF")"
  echo "release artifact comparison: repository has no release tag" >&2
fi

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ "$path" =~ $SHIPPED_PATTERN ]]; then
    echo "release artifact changed: $path" >&2
    exit 0
  fi
done <<< "$CHANGED"

echo "release artifact unchanged" >&2
exit 1
