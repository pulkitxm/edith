#!/usr/bin/env bash
set -euo pipefail

[[ $# -gt 0 ]] || { echo "release build blocked: command is required" >&2; exit 1; }

if [[ -n "${REBUILD:-}" ]]; then
  exec "$@"
fi

EXPECTED_SHA="${BUILT_SHA:?release build blocked: BUILT_SHA is required}"
REMOTE_NAME="${RELEASE_REMOTE_NAME:-origin}"
REMOTE_REF="${RELEASE_REMOTE_REF:-refs/heads/main}"
CHECK_INTERVAL="${RELEASE_CHECK_INTERVAL_SECONDS:-15}"
TERMINATION_GRACE_TICKS="${RELEASE_TERMINATION_GRACE_TICKS:-50}"
REMOTE_RETRY_ATTEMPTS="${RELEASE_REMOTE_RETRY_ATTEMPTS:-4}"
REMOTE_RETRY_DELAY="${RELEASE_REMOTE_RETRY_DELAY_SECONDS:-5}"
SUPERSEDED_FILE="${RELEASE_SUPERSEDED_FILE:?release build blocked: RELEASE_SUPERSEDED_FILE is required}"

case "$CHECK_INTERVAL" in
  ''|*[!0-9]*|0) echo "release build blocked: check interval must be a positive integer" >&2; exit 1 ;;
esac
case "$TERMINATION_GRACE_TICKS" in
  ''|*[!0-9]*|0) echo "release build blocked: termination grace must be a positive integer" >&2; exit 1 ;;
esac
case "$REMOTE_RETRY_ATTEMPTS" in
  ''|*[!0-9]*|0) echo "release build blocked: remote retry attempts must be a positive integer" >&2; exit 1 ;;
esac
case "$REMOTE_RETRY_DELAY" in
  ''|*[!0-9]*) echo "release build blocked: remote retry delay must be a non-negative integer" >&2; exit 1 ;;
esac

current_sha() {
  local attempt output sha
  for ((attempt = 1; attempt <= REMOTE_RETRY_ATTEMPTS; attempt += 1)); do
    output=""
    if output="$(git ls-remote --exit-code "$REMOTE_NAME" "$REMOTE_REF")"; then
      sha="$(printf '%s\n' "$output" | awk 'NR == 1 { print $1 }')"
      if [[ -n "$sha" ]]; then
        printf '%s\n' "$sha"
        return 0
      fi
    fi
    if [[ "$attempt" -eq "$REMOTE_RETRY_ATTEMPTS" ]]; then
      return 1
    fi
    echo "release remote check unavailable: retrying ($attempt/$REMOTE_RETRY_ATTEMPTS)" >&2
    [[ "$REMOTE_RETRY_DELAY" -eq 0 ]] || sleep "$REMOTE_RETRY_DELAY"
  done
  return 1
}

release_superseded() {
  : > "$SUPERSEDED_FILE"
  echo "release superseded: main moved during the release build" >&2
  exit 75
}

CURRENT_SHA="$(current_sha)" \
  || { echo "release build blocked: could not resolve $REMOTE_REF" >&2; exit 1; }
[[ "$CURRENT_SHA" == "$EXPECTED_SHA" ]] || release_superseded

set -m
"$@" &
BUILD_PID=$!
BUILD_PGID=$BUILD_PID
set +m

stop_build() {
  local attempt
  kill -TERM -- "-$BUILD_PGID" 2>/dev/null || true
  for ((attempt = 0; attempt < TERMINATION_GRACE_TICKS; attempt += 1)); do
    kill -0 -- "-$BUILD_PGID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 -- "-$BUILD_PGID" 2>/dev/null; then
    kill -KILL -- "-$BUILD_PGID" 2>/dev/null || true
  fi
  wait "$BUILD_PID" 2>/dev/null || true
}

trap 'stop_build; exit 130' HUP INT TERM

ELAPSED=0
while kill -0 "$BUILD_PID" 2>/dev/null; do
  sleep 1
  kill -0 "$BUILD_PID" 2>/dev/null || break
  ELAPSED=$((ELAPSED + 1))
  [[ "$ELAPSED" -lt "$CHECK_INTERVAL" ]] && continue
  ELAPSED=0
  CURRENT_SHA="$(current_sha)" \
    || { stop_build; echo "release build blocked: could not resolve $REMOTE_REF" >&2; exit 1; }
  if [[ "$CURRENT_SHA" != "$EXPECTED_SHA" ]]; then
    stop_build
    release_superseded
  fi
done

BUILD_STATUS=0
wait "$BUILD_PID" || BUILD_STATUS=$?
trap - HUP INT TERM
[[ "$BUILD_STATUS" -eq 0 ]] || exit "$BUILD_STATUS"
CURRENT_SHA="$(current_sha)" \
  || { echo "release build blocked: could not resolve $REMOTE_REF" >&2; exit 1; }
[[ "$CURRENT_SHA" == "$EXPECTED_SHA" ]] || release_superseded
exit "$BUILD_STATUS"
