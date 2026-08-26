#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

PROCESS="EdithHelper"
SAMPLE_COUNT=30
INTERVAL=1
LABEL=""
OUTPUT="json"
FIXTURE=""
PID_VALUE=""

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-2}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --process) PROCESS="${2:-}"; shift 2 ;;
    --pid) PID_VALUE="${2:-}"; shift 2 ;;
    --samples) SAMPLE_COUNT="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --fixture) FIXTURE="${2:-}"; shift 2 ;;
    *) fail "unknown flag: $1" ;;
  esac
done

[[ "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "--samples must be a positive integer"
[[ "$INTERVAL" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || fail "--interval must be a non-negative number"
[[ "$OUTPUT" == "json" || "$OUTPUT" == "text" ]] || fail "--output must be json or text"

cpu_samples=()
rss_samples=()
wake_samples=()

append_sample() {
  local cpu="$1"
  local rss="$2"
  local wake="${3:-}"
  [[ "$cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid cpu sample: $cpu"
  [[ "$rss" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid rss sample: $rss"
  if [[ -n "$wake" ]]; then
    [[ "$wake" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid wakeup sample: $wake"
    wake_samples+=("$wake")
  fi
  cpu_samples+=("$cpu")
  rss_samples+=("$(awk -v value="$rss" 'BEGIN { printf "%.3f", value / 1024 }')")
}

if [[ -n "$FIXTURE" ]]; then
  [[ -f "$FIXTURE" ]] || fail "fixture not found: $FIXTURE" 1
  while read -r cpu rss wake extra; do
    [[ -z "${cpu:-}" ]] && continue
    [[ -z "${extra:-}" ]] || fail "fixture rows require cpu, rss_kb, and optional wakeups"
    append_sample "$cpu" "$rss" "${wake:-}"
  done < "$FIXTURE"
  PROCESS="fixture"
  PID_VALUE="0"
else
  if [[ -z "$PID_VALUE" ]]; then
    matches="$(pgrep -x "$PROCESS" || true)"
    [[ -n "$matches" ]] || fail "no running process named '$PROCESS'" 1
    [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" == "1" ]] \
      || fail "multiple '$PROCESS' processes found; pass --pid" 1
    PID_VALUE="$matches"
  fi
  [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] || fail "--pid must be a positive integer"
  printf 'sampling pid %s (%s), %s samples\n' "$PID_VALUE" "$PROCESS" "$SAMPLE_COUNT" >&2
  for ((index = 0; index < SAMPLE_COUNT; index += 1)); do
    sample="$(ps -o %cpu=,rss= -p "$PID_VALUE" 2>/dev/null || true)"
    read -r cpu rss extra <<< "$sample"
    [[ -n "${cpu:-}" && -n "${rss:-}" && -z "${extra:-}" ]] \
      || fail "process exited during sampling" 1
    append_sample "$cpu" "$rss"
    if ((index + 1 < SAMPLE_COUNT)); then sleep "$INTERVAL"; fi
  done
  if top_output="$(
    top -l 2 -s 1 -stats pid,idlew -pid "$PID_VALUE" 2>/dev/null
  )"; then
    wake="$(
      awk -v pid="$PID_VALUE" '$1 == pid { value = $2 } END { print value }' <<< "$top_output"
    )"
    if [[ "$wake" =~ ^[0-9]+([.][0-9]+)?$ ]]; then wake_samples+=("$wake"); fi
  fi
fi

[[ "${#cpu_samples[@]}" -gt 0 ]] || fail "no samples collected" 1

percentile() {
  local percent="$1"
  sort -n | awk -v percent="$percent" '
    { values[NR] = $1 }
    END {
      if (NR == 0) { print "0.000"; exit }
      position = int((NR * percent + 99) / 100)
      if (position < 1) position = 1
      if (position > NR) position = NR
      printf "%.3f", values[position]
    }
  '
}

median() {
  sort -n | awk '
    { values[NR] = $1 }
    END {
      if (NR == 0) { print "0.000"; exit }
      if (NR % 2) printf "%.3f", values[(NR + 1) / 2]
      else printf "%.3f", (values[NR / 2] + values[NR / 2 + 1]) / 2
    }
  '
}

maximum() {
  sort -n | tail -1 | awk '{ printf "%.3f", $1 }'
}

json_array() {
  local first=1
  printf '['
  for value in "$@"; do
    if [[ "$first" == 0 ]]; then printf ','; fi
    printf '%.3f' "$value"
    first=0
  done
  printf ']'
}

cpu_median="$(printf '%s\n' "${cpu_samples[@]}" | median)"
cpu_p95="$(printf '%s\n' "${cpu_samples[@]}" | percentile 95)"
cpu_peak="$(printf '%s\n' "${cpu_samples[@]}" | maximum)"
rss_median="$(printf '%s\n' "${rss_samples[@]}" | median)"
rss_p95="$(printf '%s\n' "${rss_samples[@]}" | percentile 95)"
rss_peak="$(printf '%s\n' "${rss_samples[@]}" | maximum)"
wake_median="null"
if [[ "${#wake_samples[@]}" -gt 0 ]]; then
  wake_median="$(printf '%s\n' "${wake_samples[@]}" | median)"
fi

[[ -n "$LABEL" ]] || LABEL="$PROCESS"
escaped_label="${LABEL//\\/\\\\}"
escaped_label="${escaped_label//\"/\\\"}"
escaped_process="${PROCESS//\\/\\\\}"
escaped_process="${escaped_process//\"/\\\"}"

if [[ "$OUTPUT" == "text" ]]; then
  printf '%s | samples %s | cpu median %.3f%% p95 %.3f%% peak %.3f%% | rss median %.3f MB p95 %.3f MB peak %.3f MB | idle wakeups median %s\n' \
    "$LABEL" "${#cpu_samples[@]}" "$cpu_median" "$cpu_p95" "$cpu_peak" \
    "$rss_median" "$rss_p95" "$rss_peak" "$wake_median"
else
  printf '{"schemaVersion":1,"label":"%s","process":"%s","pid":%s,"samples":%s,' \
    "$escaped_label" "$escaped_process" "$PID_VALUE" "${#cpu_samples[@]}"
  printf '"cpuPercent":{"median":%.3f,"p95":%.3f,"peak":%.3f},' \
    "$cpu_median" "$cpu_p95" "$cpu_peak"
  printf '"rssMB":{"median":%.3f,"p95":%.3f,"peak":%.3f},"idleWakeups":{"median":%s},' \
    "$rss_median" "$rss_p95" "$rss_peak" "$wake_median"
  printf '"raw":{"cpuPercent":'
  json_array "${cpu_samples[@]}"
  printf ',"rssMB":'
  json_array "${rss_samples[@]}"
  printf ',"idleWakeups":'
  json_array "${wake_samples[@]}"
  printf '}}\n'
fi
