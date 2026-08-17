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

platform=$(uname -s 2>/dev/null || printf unknown)
previous_cpu_total=
previous_cpu_idle=
previous_cpu_steal=
previous_disk_read=
previous_disk_write=
previous_net_rx=
previous_net_tx=

emit_hello_macos() {
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

emit_hello_linux() {
  os=$(awk -F= '$1 == "PRETTY_NAME" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' /etc/os-release 2>/dev/null || printf Linux)
  os=${os:-Linux}
  kernel=$(uname -r 2>/dev/null || printf unknown)
  arch=$(uname -m 2>/dev/null || printf unknown)
  host=$(hostname 2>/dev/null || printf unknown)
  cpu=$(awk -F: '/^(model name|Hardware)[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null || printf unknown)
  cpu=${cpu:-unknown}
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 0)
  memory_kb=$(awk '$1 == "MemTotal:" { print $2; exit }' /proc/meminfo 2>/dev/null || printf 0)
  memory_kb=${memory_kb:-0}
  virtual=false
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet 2>/dev/null; then
    virtual=true
  fi
  printf '@EDITH@{"t":"hello","v":1,"os":"%s","osID":"linux","kernel":"%s","arch":"%s","host":"%s","cpuModel":"%s","cores":%s,"memTotalKB":%s,"virtual":%s}\n' \
    "$(printf '%s' "$os" | escape)" "$(printf '%s' "$kernel" | escape)" \
    "$(printf '%s' "$arch" | escape)" "$(printf '%s' "$host" | escape)" \
    "$(printf '%s' "$cpu" | escape)" "$cores" "$memory_kb" "$virtual"
}

emit_sample_macos() {
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

emit_sample_linux() {
  timestamp=$(date +%s)
  set -- $(awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print total, idle, $9; exit }' /proc/stat)
  cpu_total=${1:-0}; cpu_idle=${2:-0}; cpu_steal=${3:-0}
  if [ -n "$previous_cpu_total" ] && [ "$cpu_total" -gt "$previous_cpu_total" ]; then
    cpu=$(awk -v total="$cpu_total" -v idle="$cpu_idle" -v previous_total="$previous_cpu_total" -v previous_idle="$previous_cpu_idle" 'BEGIN { printf "%.1f", 100 * ((total - previous_total) - (idle - previous_idle)) / (total - previous_total) }')
    steal=$(awk -v value="$cpu_steal" -v previous="$previous_cpu_steal" -v total="$cpu_total" -v previous_total="$previous_cpu_total" 'BEGIN { printf "%.1f", 100 * (value - previous) / (total - previous_total) }')
  else
    cpu=0
    steal=0
  fi
  previous_cpu_total=$cpu_total
  previous_cpu_idle=$cpu_idle
  previous_cpu_steal=$cpu_steal

  set -- $(awk '
    $1 == "MemTotal:" { total=$2 }
    $1 == "MemAvailable:" { available=$2 }
    $1 == "MemFree:" { free=$2 }
    $1 == "Buffers:" { buffers=$2 }
    $1 == "Cached:" { cached=$2 }
    $1 == "SReclaimable:" { reclaimable=$2 }
    $1 == "SwapTotal:" { swap_total=$2 }
    $1 == "SwapFree:" { swap_free=$2 }
    END { if (!available) available=free+buffers+cached; cache=buffers+cached+reclaimable; used=total-available; print total+0, available+0, used+0, cache+0, swap_total+0, swap_total-swap_free }
  ' /proc/meminfo)
  total_kb=${1:-0}; available_kb=${2:-0}; used_kb=${3:-0}; cache_kb=${4:-0}; swap_total_kb=${5:-0}; swap_used_kb=${6:-0}

  set -- $(awk '{ split($4, tasks, "/"); print $1, $2, $3, tasks[1], tasks[2] }' /proc/loadavg)
  load1=${1:-0}; load5=${2:-0}; load15=${3:-0}; runnable=${4:-0}; tasks=${5:-0}
  uptime=$(awk '{ printf "%d", $1 }' /proc/uptime)

  set -- $(awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ { read+=$6; write+=$10 } END { print read+0, write+0 }' /proc/diskstats)
  disk_read=${1:-0}; disk_write=${2:-0}
  if [ -n "$previous_disk_read" ]; then
    disk_read_bps=$(( (disk_read - previous_disk_read) * 512 / interval ))
    disk_write_bps=$(( (disk_write - previous_disk_write) * 512 / interval ))
  else
    disk_read_bps=0
    disk_write_bps=0
  fi
  previous_disk_read=$disk_read
  previous_disk_write=$disk_write

  set -- $(awk 'NR > 2 { gsub(/:/, "", $1); if ($1 != "lo") { rx+=$2; tx+=$10 } } END { print rx+0, tx+0 }' /proc/net/dev)
  net_rx=${1:-0}; net_tx=${2:-0}
  if [ -n "$previous_net_rx" ]; then
    net_rx_bps=$(( (net_rx - previous_net_rx) / interval ))
    net_tx_bps=$(( (net_tx - previous_net_tx) / interval ))
  else
    net_rx_bps=0
    net_tx_bps=0
  fi
  previous_net_rx=$net_rx
  previous_net_tx=$net_tx

  processes=$(ps -eo pid=,user=,%cpu=,%mem=,rss=,comm= 2>/dev/null | sort -k3 -nr | head -15 | awk '
    function esc(s, out, i, c) { out=""; for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c=="\\") out=out "\\\\"; else if (c=="\"") out=out "\\\""; else out=out c } return out }
    BEGIN { first=1 }
    NF >= 6 { if (!first) printf ","; printf "{\"pid\":%d,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"rssKB\":%d,\"name\":\"%s\",\"cmd\":\"%s\"}", $1, esc($2), $3, $4, $5, esc($6), esc($6); first=0 }
  ')
  printf '@EDITH@{"t":"sample","ts":%s,"dt":%s,"cpu":{"total":%s,"steal":%s,"cores":[]},"mem":{"totalKB":%s,"availKB":%s,"usedKB":%s,"buffcacheKB":%s,"swapTotalKB":%s,"swapUsedKB":%s},"load":[%s,%s,%s],"tasks":{"runnable":%s,"total":%s},"uptime":%s,"disk":{"devices":[],"readBps":%s,"writeBps":%s},"net":{"ifaces":[],"rxBps":%s,"txBps":%s},"procs":[%s]}\n' \
    "$timestamp" "$interval" "$cpu" "$steal" "$total_kb" "$available_kb" "$used_kb" "$cache_kb" "$swap_total_kb" "$swap_used_kb" \
    "$load1" "$load5" "$load15" "$runnable" "$tasks" "$uptime" "$disk_read_bps" "$disk_write_bps" "$net_rx_bps" "$net_tx_bps" "$processes"
}

filesystem_json() {
  df -Pk 2>/dev/null | awk '
    function esc(s, out, i, c) { out=""; for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c=="\\") out=out "\\\\"; else if (c=="\"") out=out "\\\""; else out=out c } return out }
    BEGIN { first=1 }
    NR > 1 && $1 ~ /^\/dev\// { if (!first) printf ","; printf "{\"fs\":\"%s\",\"mount\":\"%s\",\"totalKB\":%d,\"usedKB\":%d,\"availKB\":%d}", esc($1), esc($6), $2, $3, $4; first=0 }
  '
}

linux_temperature_json() {
  first=true
  for file in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$file" ] || continue
    raw=$(awk 'NR == 1 { print int($1); exit }' "$file" 2>/dev/null || printf 0)
    [ "$raw" -gt 0 ] || continue
    directory=${file%/temp}
    label=$(cat "$directory/type" 2>/dev/null || basename "$directory")
    c=$(awk -v value="$raw" 'BEGIN { if (value > 1000) printf "%.1f", value / 1000; else printf "%.1f", value }')
    [ "$first" = true ] || printf ','
    printf '{"label":"%s","c":%s}' "$(printf '%s' "$label" | escape)" "$c"
    first=false
  done
}

linux_battery_json() {
  for directory in /sys/class/power_supply/BAT*; do
    [ -d "$directory" ] || continue
    percent=$(cat "$directory/capacity" 2>/dev/null || printf 0)
    status=$(cat "$directory/status" 2>/dev/null || printf Unknown)
    printf '{"percent":%s,"status":"%s"}' "$percent" "$(printf '%s' "$status" | escape)"
    return
  done
  printf null
}

emit_slow() {
  disks=$(filesystem_json)
  if [ "$platform" = Linux ]; then
    temps=$(linux_temperature_json)
    battery=$(linux_battery_json)
  else
    temps=
    battery=null
  fi
  printf '@EDITH@{"t":"slow","disks":[%s],"temps":[%s],"fans":[],"battery":%s,"gpu":null}\n' "$disks" "$temps" "$battery"
}

case "$platform" in
  Darwin) emit_hello_macos ;;
  Linux) emit_hello_linux ;;
  *) exit 1 ;;
esac

while :; do
  case "$platform" in
    Darwin) emit_sample_macos ;;
    Linux) emit_sample_linux ;;
  esac
  emit_slow
  [ "$mode" = once ] && break
  sleep "$interval"
done
