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
platform=$(uname -s 2>/dev/null || printf unknown)

if [ "$platform" = Linux ]; then
exec awk -v mode="$mode" -v interval="$interval" '
function jesc(s,  out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c < " ") out = out " "
    else out = out c
  }
  return out
}
function readfile(path,  line, all) {
  all = ""
  while ((getline line < path) > 0) {
    all = all line "\n"
  }
  close(path)
  return all
}
function firstline(path,  line) {
  line = ""
  if ((getline line < path) > 0) { close(path); return line }
  close(path)
  return ""
}
function clamp0(x) { return x < 0 ? 0 : x }
function readstat(  line, n, parts, label, busy, idle_all, i) {
  delete curCpuBusy; delete curCpuTotal; delete coreNames
  nCores = 0
  while ((getline line < "/proc/stat") > 0) {
    if (line !~ /^cpu/) continue
    n = split(line, parts, " ")
    label = parts[1]
    for (i = n + 1; i <= 11; i++) parts[i] = 0
    busy = parts[2] + parts[3] + parts[4] + parts[7] + parts[8] + parts[9]
    idle_all = parts[5] + parts[6]
    curCpuBusy[label] = busy
    curCpuTotal[label] = busy + idle_all
    curCpuSteal[label] = parts[9]
    if (label != "cpu") { nCores++; coreNames[nCores] = label }
  }
  close("/proc/stat")
}
function readmem(  line, parts) {
  memTotal = 0; memFree = 0; memAvail = -1; buffers = 0; cached = 0
  sreclaim = 0; shmem = 0; swapTotal = 0; swapFree = 0
  while ((getline line < "/proc/meminfo") > 0) {
    split(line, parts, " ")
    if (parts[1] == "MemTotal:") memTotal = parts[2]
    else if (parts[1] == "MemFree:") memFree = parts[2]
    else if (parts[1] == "MemAvailable:") memAvail = parts[2]
    else if (parts[1] == "Buffers:") buffers = parts[2]
    else if (parts[1] == "Cached:") cached = parts[2]
    else if (parts[1] == "SReclaimable:") sreclaim = parts[2]
    else if (parts[1] == "Shmem:") shmem = parts[2]
    else if (parts[1] == "SwapTotal:") swapTotal = parts[2]
    else if (parts[1] == "SwapFree:") swapFree = parts[2]
  }
  close("/proc/meminfo")
  if (memAvail < 0) {
    memAvail = clamp0(memFree + buffers + cached + sreclaim - shmem)
  }
}
function readdisks(  line, parts, name) {
  delete curDiskRead; delete curDiskWrite; delete curDiskMs
  while ((getline line < "/proc/diskstats") > 0) {
    split(line, parts, " ")
    name = parts[3]
    if (name ~ /^(loop|ram|zram|fd|sr)/) continue
    if (!(name in blockDevices)) continue
    curDiskRead[name] = parts[6]
    curDiskWrite[name] = parts[10]
    curDiskMs[name] = parts[13]
  }
  close("/proc/diskstats")
}
function readnet(  line, idx, name, rest, parts) {
  delete curNetRx; delete curNetTx
  netHeader = 2
  while ((getline line < "/proc/net/dev") > 0) {
    if (netHeader > 0) { netHeader--; continue }
    idx = index(line, ":")
    if (idx == 0) continue
    name = substr(line, 1, idx - 1)
    gsub(/ /, "", name)
    if (name == "lo") continue
    rest = substr(line, idx + 1)
    split(rest, parts, " ")
    curNetRx[name] = parts[1]
    curNetTx[name] = parts[9]
  }
  close("/proc/net/dev")
}
function readpid(pid,  line, rest, n, parts, ticks, start, rss, uid, pname, open) {
  if (pid == selfPid) return
  line = firstline("/proc/" pid "/stat")
  if (line == "") return
  n = index(line, ")")
  if (n == 0) return
  while (index(substr(line, n + 1), ")") > 0) n += index(substr(line, n + 1), ")")
  rest = substr(line, n + 2)
  split(rest, parts, " ")
  if (parts[2] == selfPid) return
  ticks = parts[12] + parts[13]
  start = parts[20]
  rss = 0; uid = ""; pname = ""
  while ((getline line < ("/proc/" pid "/status")) > 0) {
    if (line ~ /^Name:/) { sub(/^Name:[ \t]*/, "", line); pname = line }
    else if (line ~ /^Uid:/) { split(line, uparts, "\t"); uid = uparts[2] }
    else if (line ~ /^VmRSS:/) { split(line, rparts, " "); rss = rparts[2]; break }
  }
  close("/proc/" pid "/status")
  pidSeen[pid] = 1
  pidTicks[pid] = ticks
  pidStart[pid] = start
  pidRss[pid] = rss
  pidUid[pid] = uid
  pidName[pid] = pname
}
function username(uid,  line, parts) {
  if (uid == "") return ""
  if (uid in userCache) return userCache[uid]
  while ((getline line < "/etc/passwd") > 0) {
    split(line, parts, ":")
    if (parts[3] == uid) { userCache[uid] = parts[1]; close("/etc/passwd"); return parts[1] }
  }
  close("/etc/passwd")
  userCache[uid] = uid
  return uid
}
function cmdline(pid) {
  return pidCommand[pid]
}
function emit_hello(  os, osid, line, model, virt) {
  os = ""; osid = ""
  while ((getline line < "/etc/os-release") > 0) {
    if (line ~ /^PRETTY_NAME=/) { sub(/^PRETTY_NAME=/, "", line); gsub(/"/, "", line); os = line }
    if (line ~ /^ID=/ && line !~ /^ID_LIKE/) { sub(/^ID=/, "", line); gsub(/"/, "", line); osid = line }
  }
  close("/etc/os-release")
  model = ""
  while ((getline line < "/proc/cpuinfo") > 0) {
    if (line ~ /^model name/) {
      sub(/^model name[ \t]*: */, "", line); model = line; break
    }
  }
  close("/proc/cpuinfo")
  if (model == "") {
    model = firstline("/proc/device-tree/model")
  }
  virt = 0
  line = readfile("/proc/cpuinfo")
  if (line ~ /hypervisor/) virt = 1
  printf "@EDITH@{\"t\":\"hello\",\"v\":1,\"os\":\"%s\",\"osID\":\"%s\",\"kernel\":\"%s\",\"arch\":\"%s\",\"host\":\"%s\",\"cpuModel\":\"%s\",\"cores\":%d,\"memTotalKB\":%d,\"virtual\":%s}\n", jesc(os), jesc(osid), jesc(hello["kernel"]), jesc(hello["arch"]), jesc(hello["node"]), jesc(model), nCores, memTotal, virt ? "true" : "false"
  fflush()
}
function emit_sample(dt,  out, i, label, busyD, totalD, pct, stealPct, first, name, rd, wr, busyMs, rxT, txT, pid, k, bestPid, bestVal, chosen, cnt, cpuPct, memPct, cmd, uname_, aggBusyD, aggTotalD) {
  aggBusyD = clamp0(curCpuBusy["cpu"] - prevCpuBusy["cpu"])
  aggTotalD = clamp0(curCpuTotal["cpu"] - prevCpuTotal["cpu"])
  pct = aggTotalD > 0 ? 100 * aggBusyD / aggTotalD : 0
  stealPct = aggTotalD > 0 ? 100 * clamp0(curCpuSteal["cpu"] - prevCpuSteal["cpu"]) / aggTotalD : 0
  out = sprintf("{\"t\":\"sample\",\"ts\":%d,\"dt\":%.2f,\"cpu\":{\"total\":%.1f,\"steal\":%.1f,\"cores\":[", ts, dt, pct, stealPct)
  first = 1
  for (i = 1; i <= nCores; i++) {
    label = coreNames[i]
    busyD = clamp0(curCpuBusy[label] - prevCpuBusy[label])
    totalD = clamp0(curCpuTotal[label] - prevCpuTotal[label])
    out = out (first ? "" : ",") sprintf("%.1f", totalD > 0 ? 100 * busyD / totalD : 0)
    first = 0
  }
  out = out sprintf("]},\"mem\":{\"totalKB\":%d,\"availKB\":%d,\"usedKB\":%d,\"buffcacheKB\":%d,\"swapTotalKB\":%d,\"swapUsedKB\":%d}", memTotal, memAvail, clamp0(memTotal - memAvail), buffers + cached + sreclaim, swapTotal, clamp0(swapTotal - swapFree))
  out = out sprintf(",\"load\":[%s,%s,%s],\"tasks\":{\"runnable\":%d,\"total\":%d},\"uptime\":%.0f", load1, load5, load15, runnable, tasks, uptimeS)
  rd = 0; wr = 0
  out = out ",\"disk\":{\"devices\":["
  first = 1
  for (name in curDiskRead) {
    if (!(name in prevDiskRead)) continue
    busyMs = clamp0(curDiskMs[name] - prevDiskMs[name])
    i = clamp0(curDiskRead[name] - prevDiskRead[name]) * 512 / dt
    k = clamp0(curDiskWrite[name] - prevDiskWrite[name]) * 512 / dt
    rd += i; wr += k
    pct = 100 * busyMs / (dt * 1000); if (pct > 100) pct = 100
    out = out (first ? "" : ",") sprintf("{\"n\":\"%s\",\"readBps\":%.0f,\"writeBps\":%.0f,\"busy\":%.1f}", jesc(name), i, k, pct)
    first = 0
  }
  out = out sprintf("],\"readBps\":%.0f,\"writeBps\":%.0f}", rd, wr)
  rxT = 0; txT = 0
  out = out ",\"net\":{\"ifaces\":["
  first = 1
  for (name in curNetRx) {
    if (!(name in prevNetRx)) continue
    i = clamp0(curNetRx[name] - prevNetRx[name]) / dt
    k = clamp0(curNetTx[name] - prevNetTx[name]) / dt
    rxT += i; txT += k
    out = out (first ? "" : ",") sprintf("{\"n\":\"%s\",\"rxBps\":%.0f,\"txBps\":%.0f,\"virtual\":%s}", jesc(name), i, k, (name ~ /^(veth|br-|docker|virbr|podman|flannel|cni|tap|tun)/) ? "true" : "false")
    first = 0
  }
  out = out sprintf("],\"rxBps\":%.0f,\"txBps\":%.0f}", rxT, txT)
  out = out ",\"procs\":["
  delete chosenSet
  for (cnt = 1; cnt <= 15; cnt++) {
    bestPid = ""; bestVal = -1
    for (pid in pidSeen) {
      if (pid in chosenSet) continue
      if (!(pid in prevPidTicks) || prevPidStart[pid] != pidStart[pid]) continue
      k = clamp0(pidTicks[pid] - prevPidTicks[pid])
      if (k > bestVal) { bestVal = k; bestPid = pid }
    }
    if (bestPid == "" || bestVal <= 0) break
    chosenSet[bestPid] = 1
  }
  for (cnt = 1; cnt <= 15; cnt++) {
    bestPid = ""; bestVal = -1
    for (pid in pidSeen) {
      if (pid in chosenSet) continue
      if (pidRss[pid] + 0 > bestVal) { bestVal = pidRss[pid] + 0; bestPid = pid }
    }
    if (bestPid == "") break
    chosenSet[bestPid] = 1
  }
  first = 1
  for (pid in chosenSet) {
    cpuPct = 0
    if ((pid in prevPidTicks) && prevPidStart[pid] == pidStart[pid] && aggTotalD > 0) {
      cpuPct = 100 * clamp0(pidTicks[pid] - prevPidTicks[pid]) / aggTotalD * nCores
    }
    memPct = memTotal > 0 ? 100 * pidRss[pid] / memTotal : 0
    cmd = cmdline(pid)
    if (cmd == "") cmd = "[" pidName[pid] "]"
    uname_ = username(pidUid[pid])
    out = out (first ? "" : ",") sprintf("{\"pid\":%d,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"rssKB\":%d,\"name\":\"%s\",\"cmd\":\"%s\"}", pid, jesc(uname_), cpuPct, memPct, pidRss[pid], jesc(pidName[pid]), jesc(cmd))
    first = 0
  }
  out = out "]}"
  printf "@EDITH@%s\n", out
  fflush()
}
function emit_slow(  out, i, first, parts, dev, seenDev, label, temp, path, name2, j, bat, rpm, currentProfile, profileLine, nProfiles) {
  out = "{\"t\":\"slow\",\"disks\":["
  first = 1
  delete seenDev
  for (i = 1; i <= nDf; i++) {
    split(dfLines[i], parts, " ")
    if (parts[1] !~ /^\//) continue
    if (parts[1] in seenDev) continue
    seenDev[parts[1]] = 1
    dev = dfLines[i]
    sub(/^[^ ]+[ ]+[^ ]+[ ]+[^ ]+[ ]+[^ ]+[ ]+[^ ]+[ ]+/, "", dev)
    out = out (first ? "" : ",") sprintf("{\"fs\":\"%s\",\"mount\":\"%s\",\"totalKB\":%d,\"usedKB\":%d,\"availKB\":%d}", jesc(parts[1]), jesc(dev), parts[2], parts[3], parts[4])
    first = 0
  }
  out = out "],\"temps\":["
  first = 1
  for (i = 1; i <= nThermal; i++) {
    path = thermalZones[i]
    temp = firstline(path "/temp") + 0
    temp = temp / 1000
    if (temp < -40 || temp > 250) continue
    label = firstline(path "/type")
    out = out (first ? "" : ",") sprintf("{\"label\":\"%s\",\"c\":%.1f}", jesc(label), temp)
    first = 0
  }
  for (i = 1; i <= nHwmon; i++) {
    path = hwmonDirs[i]
    name2 = firstline(path "/name")
    for (j = 1; j <= 8; j++) {
      temp = firstline(path "/temp" j "_input")
      if (temp == "") temp = firstline(path "/device/temp" j "_input")
      if (temp == "") continue
      temp = temp / 1000
      if (temp < -40 || temp > 250) continue
      label = firstline(path "/temp" j "_label")
      if (label == "") label = name2 " " j
      out = out (first ? "" : ",") sprintf("{\"label\":\"%s\",\"c\":%.1f}", jesc(label), temp)
      first = 0
    }
  }
  out = out "]"
  out = out ",\"fans\":["
  first = 1
  for (i = 1; i <= nHwmon; i++) {
    path = hwmonDirs[i]
    name2 = firstline(path "/name")
    for (j = 1; j <= 8; j++) {
      rpm = firstline(path "/fan" j "_input")
      if (rpm == "" || rpm + 0 < 0 || rpm + 0 > 100000) continue
      label = firstline(path "/fan" j "_label")
      if (label == "") label = name2 " fan " j
      out = out (first ? "" : ",") sprintf("{\"label\":\"%s\",\"rpm\":%d}", jesc(label), rpm + 0)
      first = 0
    }
  }
  out = out "]"
  currentProfile = firstline("/sys/firmware/acpi/platform_profile")
  profileLine = firstline("/sys/firmware/acpi/platform_profile_choices")
  if (currentProfile != "" && profileLine != "") {
    delete profileChoices
    nProfiles = split(profileLine, profileChoices, /[ \t]+/)
    out = out sprintf(",\"platformProfile\":{\"current\":\"%s\",\"choices\":[", jesc(currentProfile))
    first = 1
    for (i = 1; i <= nProfiles; i++) {
      if (profileChoices[i] == "") continue
      out = out (first ? "" : ",") sprintf("\"%s\"", jesc(profileChoices[i]))
      first = 0
    }
    out = out "]}"
  } else {
    out = out ",\"platformProfile\":null"
  }
  bat = ""
  for (i = 1; i <= nPsup; i++) {
    path = psupDirs[i]
    if (firstline(path "/type") != "Battery") continue
    bat = sprintf(",\"battery\":{\"percent\":%d,\"status\":\"%s\"}", firstline(path "/capacity") + 0, jesc(firstline(path "/status")))
    break
  }
  out = out bat
  if (nGpu > 0) {
    split(gpuLines[1], parts, ", ")
    out = out sprintf(",\"gpu\":{\"name\":\"%s\",\"util\":%d,\"memUsedMB\":%d,\"memTotalMB\":%d,\"temp\":%d}", jesc(parts[1]), parts[2] + 0, parts[3] + 0, parts[4] + 0, parts[5] + 0)
  }
  out = out "}"
  printf "@EDITH@%s\n", out
  fflush()
}
function rotate(  k) {
  delete prevCpuBusy; delete prevCpuTotal; delete prevCpuSteal
  for (k in curCpuBusy) prevCpuBusy[k] = curCpuBusy[k]
  for (k in curCpuTotal) prevCpuTotal[k] = curCpuTotal[k]
  for (k in curCpuSteal) prevCpuSteal[k] = curCpuSteal[k]
  delete prevDiskRead; delete prevDiskWrite; delete prevDiskMs
  for (k in curDiskRead) prevDiskRead[k] = curDiskRead[k]
  for (k in curDiskWrite) prevDiskWrite[k] = curDiskWrite[k]
  for (k in curDiskMs) prevDiskMs[k] = curDiskMs[k]
  delete prevNetRx; delete prevNetTx
  for (k in curNetRx) prevNetRx[k] = curNetRx[k]
  for (k in curNetTx) prevNetTx[k] = curNetTx[k]
  delete prevPidTicks; delete prevPidStart
  for (k in pidTicks) { prevPidTicks[k] = pidTicks[k]; prevPidStart[k] = pidStart[k] }
  delete pidSeen; delete pidTicks; delete pidStart; delete pidRss; delete pidUid; delete pidName
}
function shellLine(cmd,  line) {
  line = ""
  cmd | getline line
  close(cmd)
  return line
}
function readBlockDevices(  cmd, line) {
  delete blockDevices
  cmd = "ls -1 /sys/block 2>/dev/null"
  while ((cmd | getline line) > 0) blockDevices[line] = 1
  close(cmd)
}
function readProcessList(  cmd, line, pid) {
  delete pidList; delete pidCommand
  nPids = 0
  cmd = "ls -1 /proc 2>/dev/null"
  while ((cmd | getline line) > 0) {
    if (line !~ /^[0-9]+$/) continue
    pidList[++nPids] = line
  }
  close(cmd)
  if (nPids == 0) return
  if (commandsRetryIn > 0) { commandsRetryIn--; return }
  cmd = "F=/tmp/.edith-ps.$$; ps -ww -eo pid=,args= >$F 2>/dev/null & P=$!;"
  cmd = cmd " N=0; while kill -0 $P 2>/dev/null && [ $N -lt 3 ]; do sleep 1; N=$((N+1)); done;"
  cmd = cmd " if kill -0 $P 2>/dev/null; then echo " psStalledMarker "; else cat $F; fi; rm -f $F"
  while ((cmd | getline line) > 0) {
    if (line == psStalledMarker) { commandsRetryIn = commandsRetryEvery; continue }
    sub(/^[ \t]+/, "", line)
    pid = line
    sub(/[ \t].*$/, "", pid)
    if (pid !~ /^[0-9]+$/) continue
    sub(/^[^ \t]+[ \t]*/, "", line)
    pidCommand[pid] = line
  }
  close(cmd)
}
function readSlowInputs(  cmd, line, parts, mounts, n, i) {
  nDf = 0; nThermal = 0; nHwmon = 0; nPsup = 0; nGpu = 0
  mounts = ""
  while ((getline line < "/proc/mounts") > 0) {
    split(line, parts, " ")
    if (parts[3] == "ext4" || parts[3] == "ext3" || parts[3] == "ext2" \
      || parts[3] == "xfs" || parts[3] == "btrfs" || parts[3] == "zfs" \
      || parts[3] == "f2fs" || parts[3] == "vfat" || parts[3] == "exfat" \
      || parts[3] == "ntfs" || parts[3] == "ntfs3" \
      || (parts[3] == "overlay" && parts[2] == "/")) {
      if (index(" " mounts " ", " " parts[2] " ") == 0) {
        mounts = mounts == "" ? parts[2] : mounts " " parts[2]
      }
    }
  }
  close("/proc/mounts")
  if (mounts != "") {
    cmd = "df -Pk " mounts " 2>/dev/null"
    while ((cmd | getline line) > 0) {
      if (line ~ /^Filesystem/) continue
      nDf++
      dfLines[nDf] = line
    }
    close(cmd)
  }
  cmd = "ls -d /sys/class/thermal/thermal_zone* 2>/dev/null"
  while ((cmd | getline line) > 0) { nThermal++; thermalZones[nThermal] = line }
  close(cmd)
  cmd = "ls -d /sys/class/hwmon/hwmon* 2>/dev/null"
  while ((cmd | getline line) > 0) { nHwmon++; hwmonDirs[nHwmon] = line }
  close(cmd)
  cmd = "ls -d /sys/class/power_supply/* 2>/dev/null"
  while ((cmd | getline line) > 0) { nPsup++; psupDirs[nPsup] = line }
  close(cmd)
  cmd = "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi "
  cmd = cmd "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu "
  cmd = cmd "--format=csv,noheader,nounits 2>/dev/null"
  while ((cmd | getline line) > 0) { nGpu++; gpuLines[nGpu] = line }
  close(cmd)
}
function collect(  line, lparts, rparts, uparts, i) {
  ts = shellLine("date +%s") + 0
  readstat(); readmem(); readdisks(); readnet()
  line = firstline("/proc/loadavg")
  split(line, lparts, " ")
  load1 = lparts[1]; load5 = lparts[2]; load15 = lparts[3]
  split(lparts[4], rparts, "/")
  runnable = rparts[1]; tasks = rparts[2]
  line = firstline("/proc/uptime")
  split(line, uparts, " ")
  uptimeS = uparts[1]
  readProcessList()
  for (i = 1; i <= nPids; i++) readpid(pidList[i])
}
BEGIN {
  psStalledMarker = "@@EDITH-PS-STALLED@@"
  commandsRetryEvery = 150
  commandsRetryIn = 0
  selfPid = shellLine("echo $PPID") + 0
  hello["kernel"] = shellLine("uname -r 2>/dev/null")
  hello["arch"] = shellLine("uname -m 2>/dev/null")
  hello["node"] = shellLine("uname -n 2>/dev/null")
  readBlockDevices()
  if (interval + 0 < 1) interval = 2
  slowEvery = 15
  tick = 0
  prevTs = 0
  while (1) {
    collect()
    if (tick % slowEvery == 0) readSlowInputs()
    if (tick == 0) {
      emit_hello()
    } else if (ts > prevTs) {
      emit_sample(ts - prevTs)
    }
    if (tick % slowEvery == 0) emit_slow()
    rotate()
    prevTs = ts
    tick++
    if (mode == "once") {
      if (tick >= 2) break
      system("sleep 1")
    } else {
      system("sleep " interval)
    }
  }
}
'
fi

[ "$platform" = Darwin ] || exit 1

escape() {
  awk 'BEGIN { ORS="" } { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "\\") printf "\\\\"; else if (c == "\"") printf "\\\""; else printf "%s", c } }'
}

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

filesystem_json() {
  df -Pk 2>/dev/null | awk '
    function esc(s, out, i, c) { out=""; for (i=1; i<=length(s); i++) { c=substr(s,i,1); if (c=="\\") out=out "\\\\"; else if (c=="\"") out=out "\\\""; else out=out c } return out }
    BEGIN { first=1 }
    NR > 1 && $1 ~ /^\/dev\// { if (!first) printf ","; printf "{\"fs\":\"%s\",\"mount\":\"%s\",\"totalKB\":%d,\"usedKB\":%d,\"availKB\":%d}", esc($1), esc($6), $2, $3, $4; first=0 }
  '
}

emit_slow_macos() {
  disks=$(filesystem_json)
  printf '@EDITH@{"t":"slow","disks":[%s],"temps":[],"fans":[],"platformProfile":null,"battery":null,"gpu":null}\n' "$disks"
}

emit_hello_macos
while :; do
  emit_sample_macos
  emit_slow_macos
  [ "$mode" = once ] && break
  sleep "$interval"
done
