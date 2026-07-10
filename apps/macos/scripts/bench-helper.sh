#!/usr/bin/env bash
#
# bench-helper.sh - sample the EdithMenuBar helper's resource use in a fixed
# scenario and print a one-line result you can paste into a PR description.
#
# The Notch 2.0 plan gates each PR on these numbers not regressing. Run it
# once per scenario (idle collapsed, music playing collapsed, expanded, ...)
# and record the row.
#
#   ./scripts/bench-helper.sh                          # 60s, EdithMenuBar
#   ./scripts/bench-helper.sh --label "idle collapsed"
#   ./scripts/bench-helper.sh --seconds 30 --process Edith
#
# Measures median/peak CPU% and RSS via `ps`, and idle wakeups/s via `top`
# when a single pid matches. No sudo required.
set -euo pipefail

PROCESS="EdithMenuBar"
SECONDS_TOTAL=60
INTERVAL=2
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --process) PROCESS="$2"; shift 2 ;;
    --seconds) SECONDS_TOTAL="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

PID="$(pgrep -x "$PROCESS" | head -1 || true)"
if [[ -z "$PID" ]]; then
  PID="$(pgrep -f "$PROCESS" | head -1 || true)"
fi
if [[ -z "$PID" ]]; then
  echo "no running process matching '$PROCESS' - launch the app first" >&2
  exit 1
fi

median() {
  sort -n | awk '{ a[NR]=$1 } END {
    if (NR==0) { print "0"; exit }
    if (NR%2) { printf "%.2f", a[(NR+1)/2] }
    else { printf "%.2f", (a[NR/2] + a[NR/2+1]) / 2 }
  }'
}
maxval() { sort -n | tail -1; }

cpu_samples=()
rss_samples=()
end=$(( $(date +%s) + SECONDS_TOTAL ))
echo "sampling pid $PID ($PROCESS) for ${SECONDS_TOTAL}s..." >&2
while [[ $(date +%s) -lt $end ]]; do
  read -r cpu rss < <(ps -o %cpu=,rss= -p "$PID" 2>/dev/null || echo "0 0")
  [[ -z "$cpu" ]] && break
  cpu_samples+=("$cpu")
  rss_samples+=("$(awk -v k="$rss" 'BEGIN { printf "%.1f", k/1024 }')")
  sleep "$INTERVAL"
done

if [[ ${#cpu_samples[@]} -eq 0 ]]; then
  echo "process exited during sampling" >&2
  exit 1
fi

cpu_med=$(printf '%s\n' "${cpu_samples[@]}" | median)
cpu_max=$(printf '%s\n' "${cpu_samples[@]}" | maxval)
rss_med=$(printf '%s\n' "${rss_samples[@]}" | median)

wakeups="n/a"
if top_out=$(top -l 2 -s 1 -stats pid,idlew -pid "$PID" 2>/dev/null); then
  idlew=$(echo "$top_out" | awk -v p="$PID" '$1==p { v=$2 } END { print v }')
  if [[ -n "${idlew:-}" ]]; then
    wakeups=$(awk -v w="$idlew" 'BEGIN { printf "%.1f", w }')
  fi
fi

printf '%s | cpu median %.2f%% peak %.2f%% | rss %.1f MB | idlew %s/interval\n' \
  "${LABEL:-$PROCESS}" "$cpu_med" "$cpu_max" "$rss_med" "$wakeups"
