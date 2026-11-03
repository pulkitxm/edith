#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS="${1:-3}"
APP="$PWD/dist/Edith.app"
ED="$APP/Contents/MacOS/ed"
[ -x "$ED" ] || { echo "build the development app first: ./build.sh --no-open" >&2; exit 1; }
OUTPUT="$(mktemp -d)"
trap 'rm -rf "$OUTPUT"' EXIT

wait_until_ready() {
  for _ in $(seq 240); do
    if "$ED" extensions ls --json 2>/dev/null | python3 -c '
import json, sys
rows = [e for e in json.load(sys.stdin) if e["installed"] and e["enabled"]]
ready = all(e["state"] == "idle" or (e["state"] == "active" and any("startMs" in v for v in e["timings"].values())) for e in rows)
sys.exit(0 if ready else 1)'; then
      return 0
    fi
    sleep 0.5
  done
  echo "extensions did not become active within two minutes" >&2
  return 1
}

for run in $(seq "$RUNS"); do
  scripts/dev-slots.sh stop >/dev/null 2>&1 || true
  for _ in $(seq 60); do
    pgrep -f "$APP/Contents/MacOS/Edith$" >/dev/null || break
    sleep 0.5
  done
  open -g -j -F --env EDITH_BACKGROUND_TESTING=1 --env EDITH_USAGE_OFFLINE=1 "$APP"
  wait_until_ready
  "$ED" extensions ls --json >"$OUTPUT/$run.json"
done

python3 - "$OUTPUT" <<'PY'
import json, statistics, sys
from pathlib import Path

runs = [json.loads(path.read_text()) for path in sorted(Path(sys.argv[1]).glob("*.json"))]
keys = ["verifyMs", "loadMs", "startMs", "readyAfterLaunchMs"]
table = {}
totals = []
idle = set()
for run in runs:
    starts, ready = [], []
    idle.update(entry["id"] for entry in run if entry.get("state") == "idle")
    for entry in run:
        if not entry["installed"]:
            continue
        for role, values in entry["timings"].items():
            row = table.setdefault((entry["id"], role), {key: [] for key in keys})
            for key in keys:
                if key in values:
                    row[key].append(values[key])
            if "startMs" in values:
                starts.append(values["startMs"] + values.get("loadMs", 0))
                ready.append(values["readyAfterLaunchMs"])
    totals.append((sum(starts), max(ready, default=0)))

print(f"{'extension':14}{'role':9}" + "".join(f"{key:>20}" for key in keys))
for (identifier, role), row in sorted(table.items()):
    cells = "".join(
        f"{statistics.median(row[key]):>20.1f}" if row[key] else f"{'':>20}" for key in keys
    )
    print(f"{identifier:14}{role:9}{cells}")
start, ready = statistics.median(t[0] for t in totals), statistics.median(t[1] for t in totals)
if idle:
    print(f"\nidle until first use: {', '.join(sorted(idle))}")
print(f"\nmedian of {len(runs)} cold launches: total load and start {start:.0f} ms, all ready {ready:.0f} ms after launch")
PY
