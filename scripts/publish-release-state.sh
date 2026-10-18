#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-false}"
[[ "$RELEASE_PRERELEASE" == true || "$RELEASE_PRERELEASE" == false ]] \
  || { echo "release blocked: invalid host release channel" >&2; exit 1; }
REPO="${GITHUB_REPOSITORY:-pulkitxm/edith}"
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
  if [[ "$RELEASE_PRERELEASE" == true ]]; then
    git diff --quiet "$BUILT_SHA" -- Casks/edith.rb \
      || { echo "release blocked: preview changed the stable cask" >&2; exit 1; }
    return
  fi
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

if [[ "$RELEASE_PRERELEASE" == true && "$MODE" == rebuild ]]; then
  echo "preview rebuild leaves the stable cask unchanged"
  exit 0
fi

git fetch origin main --tags

case "$MODE" in
  cut)
    : "${BUILT_SHA:?BUILT_SHA is required}"
    : "${RELEASE_PLISTS_DIR:?RELEASE_PLISTS_DIR is required}"
    release_paths=(Resources/Info.plist Resources/HelperInfo.plist)
    if [[ "$RELEASE_PRERELEASE" != true ]]; then
      release_paths+=(Casks/edith.rb)
    fi

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

    RELEASE_SHA="$(git rev-parse origin/main)"
    if [[ "$RELEASE_SHA" != "$BUILT_SHA" ]]; then
      if [[ "$(git rev-parse "$RELEASE_SHA^")" != "$BUILT_SHA" ]] \
        || [[ "$(git show -s --format=%s "$RELEASE_SHA")" != "Release ${RELEASE_TAG} [skip ci]" ]]; then
        release_superseded
      fi
      git switch --detach "$RELEASE_SHA"
      verify_cask
    else
      [[ "$(git rev-parse HEAD)" == "$BUILT_SHA" ]] \
        || { echo "release blocked: checkout does not match the built commit" >&2; exit 1; }
      [[ -f "$RELEASE_PLISTS_DIR/Info.plist" && -f "$RELEASE_PLISTS_DIR/HelperInfo.plist" ]] \
        || { echo "release blocked: release plists are missing" >&2; exit 1; }
      cp "$RELEASE_PLISTS_DIR/Info.plist" Resources/Info.plist
      cp "$RELEASE_PLISTS_DIR/HelperInfo.plist" Resources/HelperInfo.plist
      if [[ "$RELEASE_PRERELEASE" != true ]]; then rewrite_cask; fi
      verify_cask
      git add "${release_paths[@]}"
      COMMIT_ERRORS="$(mktemp)"
      RESULT=""
      for attempt in 1 2 3 4; do
        if RESULT="$(pukbot commit create --repo "$REPO" --branch main \
          --message "Release ${RELEASE_TAG} [skip ci]" \
          "${release_paths[@]}" --json 2>"$COMMIT_ERRORS")"; then
          break
        fi
        echo "release commit attempt ${attempt} failed:" >&2
        cat "$COMMIT_ERRORS" >&2
        printf '%s\n' "$RESULT" >&2
        git fetch origin main --tags
        MAIN_SHA="$(git rev-parse origin/main)"
        if [[ "$MAIN_SHA" != "$BUILT_SHA" ]]; then
          if [[ "$(git rev-parse "$MAIN_SHA^")" == "$BUILT_SHA" ]] \
            && [[ "$(git show -s --format=%s "$MAIN_SHA")" == "Release ${RELEASE_TAG} [skip ci]" ]]; then
            RESULT="{\"resourceUrl\":\"https://github.com/${REPO}/commit/${MAIN_SHA}\"}"
            break
          fi
          release_superseded
        fi
        if [[ "$attempt" -eq 4 ]]; then
          echo "release blocked: release commit failed" >&2
          exit 1
        fi
        sleep $((attempt * ${RELEASE_RETRY_SECONDS:-15}))
      done
      rm -f "$COMMIT_ERRORS"
      RELEASE_SHA="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resourceUrl"].rsplit("/",1)[1])')"
      [[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "release blocked: invalid release commit" >&2; exit 1; }
      git fetch origin main --tags
      [[ "$(git rev-parse "$RELEASE_SHA^")" == "$BUILT_SHA" ]] \
        || release_superseded
      [[ "$(git rev-parse origin/main)" == "$RELEASE_SHA" ]] \
        || release_superseded
      git restore --source="$RELEASE_SHA" --staged --worktree -- "${release_paths[@]}"
      git switch --detach "$RELEASE_SHA"
      verify_cask
    fi
    TAG_DONE=0
    for attempt in 1 2 3 4; do
      if pukbot tag create "$RELEASE_TAG" --repo "$REPO" --target "$RELEASE_SHA" \
        --message "Edith $RELEASE_TAG build $RELEASE_BUILD" --json; then
        TAG_DONE=1
        break
      fi
      echo "release tag attempt ${attempt} failed" >&2
      git fetch origin --tags --force
      if [[ "$(git rev-parse -q --verify "refs/tags/${RELEASE_TAG}^{commit}" || true)" == "$RELEASE_SHA" ]]; then
        TAG_DONE=1
        break
      fi
      [[ "$attempt" -eq 4 ]] || sleep $((attempt * ${RELEASE_RETRY_SECONDS:-15}))
    done
    [[ "$TAG_DONE" -eq 1 ]] \
      || { echo "release blocked: release tag failed; retry the same built source" >&2; exit 1; }
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

    git add Casks/edith.rb
    pukbot commit create --repo "$REPO" --branch main \
      --message "Refresh ${RELEASE_TAG} release checksum" Casks/edith.rb --json
    ;;
  *)
    echo "usage: publish-release-state.sh cut|rebuild" >&2
    exit 2
    ;;
esac
