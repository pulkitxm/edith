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
    : "${RELEASE_PLISTS_DIR:?RELEASE_PLISTS_DIR is required}"

    REMOTE_TAG_SHA="$(remote_tag_sha)"
    if [[ -n "$REMOTE_TAG_SHA" ]]; then
      [[ "$(git rev-parse "$REMOTE_TAG_SHA^")" == "$BUILT_SHA" ]] \
        || { echo "release blocked: $RELEASE_TAG was published from another source" >&2; exit 1; }
      git merge-base --is-ancestor "$REMOTE_TAG_SHA" origin/main \
        || { echo "release blocked: $RELEASE_TAG is not on current main" >&2; exit 1; }
      git switch --detach "$REMOTE_TAG_SHA"
      verify_cask
      exit 0
    fi

    [[ "$(git rev-parse HEAD)" == "$BUILT_SHA" ]] \
      || { echo "release blocked: checkout does not match the built commit" >&2; exit 1; }
    [[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]] \
      || release_superseded
    [[ -f "$RELEASE_PLISTS_DIR/Info.plist" && -f "$RELEASE_PLISTS_DIR/HelperInfo.plist" ]] \
      || { echo "release blocked: release plists are missing" >&2; exit 1; }

    cp "$RELEASE_PLISTS_DIR/Info.plist" Resources/Info.plist
    cp "$RELEASE_PLISTS_DIR/HelperInfo.plist" Resources/HelperInfo.plist
    rewrite_cask
    verify_cask
    git \
      -c user.name="pukbot[bot]" \
      -c user.email="320458784+pukbot[bot]@users.noreply.github.com" \
      commit Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb \
      -m "Release ${RELEASE_TAG} [skip ci]"
    git \
      -c user.name="pukbot[bot]" \
      -c user.email="320458784+pukbot[bot]@users.noreply.github.com" \
      tag -a "$RELEASE_TAG" -m "Edith $RELEASE_TAG build $RELEASE_BUILD"
    if git push --atomic origin HEAD:main "refs/tags/$RELEASE_TAG"; then
      exit 0
    fi

    git fetch origin main --tags
    REMOTE_TAG_SHA="$(remote_tag_sha)"
    if [[ -n "$REMOTE_TAG_SHA" ]]; then
      [[ "$REMOTE_TAG_SHA" == "$(git rev-parse HEAD)" ]] \
        || { echo "release blocked: $RELEASE_TAG was published from another commit" >&2; exit 1; }
      exit 0
    fi
    [[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]] \
      || release_superseded
    echo "release blocked: release push failed" >&2
    exit 1
    ;;
  rebuild)
    git switch --detach origin/main
    LATEST_TAG="$(latest_release_tag)" \
      || { echo "release blocked: no current release tag is available" >&2; exit 1; }
    [[ "$LATEST_TAG" == "$RELEASE_TAG" ]] \
      || { echo "release blocked: only the current release can be rebuilt" >&2; exit 1; }
    grep -qx "  version \"$RELEASE_VERSION\"" Casks/edith.rb \
      || { echo "release blocked: only the current release can be rebuilt" >&2; exit 1; }
    rewrite_cask
    verify_cask

    if git diff --quiet -- Casks/edith.rb; then
      exit 0
    fi

    git \
      -c user.name="pukbot[bot]" \
      -c user.email="320458784+pukbot[bot]@users.noreply.github.com" \
      commit Casks/edith.rb -m "Refresh ${RELEASE_TAG} release checksum"
    git push origin HEAD:main
    ;;
  *)
    echo "usage: publish-release-state.sh cut|rebuild" >&2
    exit 2
    ;;
esac
