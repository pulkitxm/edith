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
SUPERSEDED_FILE="${RELEASE_SUPERSEDED_FILE:?release build blocked: RELEASE_SUPERSEDED_FILE is required}"

case "$CHECK_INTERVAL" in
  ''|*[!0-9]*|0) echo "release build blocked: check interval must be a positive integer" >&2; exit 1 ;;
esac
case "$TERMINATION_GRACE_TICKS" in
  ''|*[!0-9]*|0) echo "release build blocked: termination grace must be a positive integer" >&2; exit 1 ;;
esac

current_sha() {
  git ls-remote --exit-code "$REMOTE_NAME" "$REMOTE_REF" | awk 'NR == 1 { print $1 }'
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
