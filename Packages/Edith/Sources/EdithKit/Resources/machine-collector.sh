#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

interval=2
mode=stream
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) mode=once ;;
    -i) interval="${2:-2}"; shift ;;
  esac
  shift
done

escape() {
  awk 'BEGIN { ORS="" } { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "\\") printf "\\\\"; else if (c == "\"") printf "\\\""; else printf "%s", c } }'
}

emit_hello() {
  version=$(sw_vers -productVersion 2>/dev/null || printf unknown)
  kernel=$(uname -r 2>/dev/null || printf unknown)
  arch=$(uname -m 2>/dev/null || printf unknown)
  host=$(scutil --get ComputerName 2>/dev/null || hostname)
  cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)
  cores=$(sysctl -n hw.ncpu 2>/dev/null || printf 0)
  bytes=$(sysctl -n hw.memsize 2>/dev/null || printf 0)
  memory_kb=$((bytes / 1024))
  printf '@EDITH@{"t":"hello","v":1,"os":"macOS %s","osID":"macos","kernel":"%s","arch":"%s","host":"%s","cpuModel":"%s","cores":%s,"memTotalKB":%s,"virtual":false}\n' \
    "$(printf '%s' "$version" | escape)" "$(printf '%s' "$kernel" | escape)" \
    "$(printf '%s' "$arch" | escape)" "$(printf '%s' "$host" | escape)" \
    "$(printf '%s' "$cpu" | escape)" "$cores" "$memory_kb"
}

emit_sample() {
  timestamp=$(date +%s)
  cpu=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ { gsub(/%/, "", $3); gsub(/%/, "", $5); print $3 + $5; exit }')
  cpu=${cpu:-0}
  total_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || printf 0) / 1024 ))
  page_size=$(pagesize 2>/dev/null || printf 4096)
  available_kb=$(vm_stat 2>/dev/null | awk -v page="$page_size" '/Pages free|Pages inactive|Pages speculative/ { gsub(/\./, "", $3); pages += $3 } END { print int(pages * page / 1024) }')
  available_kb=${available_kb:-0}
  used_kb=$((total_kb - available_kb))
  [ "$used_kb" -ge 0 ] || used_kb=0
  set -- $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
  load1=${1:-0}; load5=${2:-0}; load15=${3:-0}
  tasks=$(ps -A -o pid= 2>/dev/null | wc -l | tr -d ' ')
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+).*/\1/')
  case "$boot" in ''|*[!0-9]*) uptime=0 ;; *) uptime=$((timestamp - boot)) ;; esac
  processes=$(ps -A -o pid=,user=,%cpu=,%mem=,rss=,comm= 2>/dev/null | sort -k3 -nr | head -15 | awk '
    function esc(s, out, i, c) { out=""; for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c=="\\") out=out "\\\\"; else if (c=="\"") out=out "\\\""; else out=out c } return out }
    BEGIN { first=1 }
    NF >= 6 { if (!first) printf ","; printf "{\"pid\":%d,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"rssKB\":%d,\"name\":\"%s\",\"cmd\":\"%s\"}", $1, esc($2), $3, $4, $5, esc($6), esc($6); first=0 }
  ')
  printf '@EDITH@{"t":"sample","ts":%s,"dt":%s,"cpu":{"total":%s,"steal":0,"cores":[]},"mem":{"totalKB":%s,"availKB":%s,"usedKB":%s,"buffcacheKB":0,"swapTotalKB":0,"swapUsedKB":0},"load":[%s,%s,%s],"tasks":{"runnable":0,"total":%s},"uptime":%s,"disk":{"devices":[],"readBps":0,"writeBps":0},"net":{"ifaces":[],"rxBps":0,"txBps":0},"procs":[%s]}\n' \
    "$timestamp" "$interval" "$cpu" "$total_kb" "$available_kb" "$used_kb" \
    "$load1" "$load5" "$load15" "$tasks" "$uptime" "$processes"
}

emit_slow() {
  disks=$(df -Pk 2>/dev/null | awk '
    function esc(s, out, i, c) { out=""; for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c=="\\") out=out "\\\\"; else if (c=="\"") out=out "\\\""; else out=out c } return out }
    BEGIN { first=1 }
    NR > 1 && $1 ~ /^\/dev\// { if (!first) printf ","; printf "{\"fs\":\"%s\",\"mount\":\"%s\",\"totalKB\":%d,\"usedKB\":%d,\"availKB\":%d}", esc($1), esc($6), $2, $3, $4; first=0 }
  ')
  printf '@EDITH@{"t":"slow","disks":[%s],"temps":[],"fans":[],"battery":null,"gpu":null}\n' "$disks"
}

emit_hello
while :; do
  emit_sample
  emit_slow
  [ "$mode" = once ] && break
  sleep "$interval"
done
