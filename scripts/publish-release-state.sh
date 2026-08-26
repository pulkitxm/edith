#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${RELEASE_BUILD:?RELEASE_BUILD is required}"
: "${RELEASE_SHA256:?RELEASE_SHA256 is required}"

[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "release blocked: invalid release version" >&2; exit 1; }
[[ "$RELEASE_TAG" == "v$RELEASE_VERSION" ]] \
  || { echo "release blocked: the tag and version do not match" >&2; exit 1; }
[[ "$RELEASE_BUILD" =~ ^[0-9]+$ ]] \
  || { echo "release blocked: invalid release build" >&2; exit 1; }
[[ "$RELEASE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "release blocked: invalid release checksum" >&2; exit 1; }

rewrite_cask() {
  sed \
    -e "s/^  version \".*\"$/  version \"$RELEASE_VERSION\"/" \
    -e "s/^  sha256 \".*\"$/  sha256 \"$RELEASE_SHA256\"/" \
    Casks/edith.rb > Casks/edith.rb.next
  mv Casks/edith.rb.next Casks/edith.rb
}

verify_cask() {
  grep -qx "  version \"$RELEASE_VERSION\"" Casks/edith.rb \
    || { echo "release blocked: the cask version does not match" >&2; exit 1; }
  grep -qx "  sha256 \"$RELEASE_SHA256\"" Casks/edith.rb \
    || { echo "release blocked: the cask checksum does not match" >&2; exit 1; }
}

remote_tag_sha() {
  git ls-remote origin "refs/tags/$RELEASE_TAG" "refs/tags/$RELEASE_TAG^{}" \
    | awk 'END { print $1 }'
}

latest_release_tag() {
  local tag
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(git tag --merged origin/main --sort=-version:refname)
  return 1
}

release_superseded() {
  echo "release superseded: main moved after the release build" >&2
  exit 75
}

git fetch origin main --tags

case "$MODE" in
  cut)
    : "${BUILT_SHA:?BUILT_SHA is required}"

    REMOTE_TAG_SHA="$(remote_tag_sha)"
    if [[ -n "$REMOTE_TAG_SHA" ]]; then
      [[ "$REMOTE_TAG_SHA" == "$BUILT_SHA" ]] \
        || { echo "release blocked: $RELEASE_TAG was published from another commit" >&2; exit 1; }
      rewrite_cask
      verify_cask
      exit 0
    fi

    [[ "$(git rev-parse HEAD)" == "$BUILT_SHA" ]] \
      || { echo "release blocked: checkout does not match the built commit" >&2; exit 1; }
    [[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]] \
      || release_superseded

    rewrite_cask
    verify_cask
    git tag -f -a "$RELEASE_TAG" -m "Edith $RELEASE_TAG build $RELEASE_BUILD" "$BUILT_SHA"
    if git push origin "refs/tags/$RELEASE_TAG"; then
      git fetch origin main
      if [[ "$(git rev-parse origin/main)" != "$BUILT_SHA" ]]; then
        git push origin ":refs/tags/$RELEASE_TAG"
        release_superseded
      fi
      exit 0
    fi

    git fetch origin main --tags
    REMOTE_TAG_SHA="$(remote_tag_sha)"
    if [[ -n "$REMOTE_TAG_SHA" ]]; then
      [[ "$REMOTE_TAG_SHA" == "$BUILT_SHA" ]] \
        || { echo "release blocked: $RELEASE_TAG was published from another commit" >&2; exit 1; }
      exit 0
    fi
    [[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]] \
      || release_superseded
    echo "release blocked: release push failed" >&2
    exit 1
    ;;
  rebuild)
    LATEST_TAG="$(latest_release_tag)" \
      || { echo "release blocked: no current release tag is available" >&2; exit 1; }
    [[ "$LATEST_TAG" == "$RELEASE_TAG" ]] \
      || { echo "release blocked: only the current release can be rebuilt" >&2; exit 1; }
    [[ "$(git rev-parse "refs/tags/$RELEASE_TAG^{commit}")" == "$(git rev-parse HEAD)" ]] \
      || { echo "release blocked: checkout does not match the release tag" >&2; exit 1; }
    rewrite_cask
    verify_cask
    ;;
  *)
    echo "usage: publish-release-state.sh cut|rebuild" >&2
    exit 2
    ;;
esac
