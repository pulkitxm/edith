#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

PROFILES = {
    "xcode": (4.0, 4096.0, "xcode build"),
    "ghostty": (6.0, 6144.0, "ghostty build"),
    "swift-test": (2.5, 2560.0, "swift test"),
    "cargo": (2.0, 2048.0, "cargo build"),
    "node": (1.5, 1024.0, "javascript toolchain"),
    "scan": (2.0, 1536.0, "security scan"),
}

EXACT = {
    "build": "xcode",
    "install": "xcode",
    "reinstall": "xcode",
    "release": "xcode",
    "release-dry": "xcode",
    "cli": "xcode",
    "ci": "xcode",
    "ci-all": "xcode",
    "ci-swift": "xcode",
    "ci-swift-check": "xcode",
    "ci-swift-build": "xcode",
    "verify-bundle": "xcode",
    "verify-release-build-settings": "xcode",
    "ghostty": "ghostty",
    "ci-swift-test": "swift-test",
    "ci-host": "swift-test",
    "ci-marketplace-host": "swift-test",
    "extension-dev": "swift-test",
    "ci-extension-support": "swift-test",
    "host": "swift-test",
    "ci-swift-test-batch": "swift-test",
    "ci-swift-lint": "swift-test",
    "ci-studio": "swift-test",
    "ci-studio-batch": "swift-test",
    "ci-browser": "swift-test",
    "ci-companion": "cargo",
    "ci-companion-migrate": "cargo",
    "ci-promo": "node",
    "ci-scripts": "node",
    "ci-scripts-batch": "node",
    "ci-performance": "node",
    "bench-cli": "node",
    "icon": "node",
    "ci-security": "scan",
    "ci-gitleaks": "scan",
    "ci-cargo-audit": "scan",
    "ci-osv": "scan",
    "ci-semgrep": "scan",
    "ci-trivy": "scan",
}

PRESSURE_SCALE = {"normal": 1.0, "warn": 0.7, "critical": 0.45}
PREFIX = "make-resource-gate"
HELD_SLOT = {"path": None}


def profile_for(goal):
    name = EXACT.get(goal)
    if name:
        return PROFILES[name]
    lowered = goal.lower()
    if "swift-test" in lowered or "studio" in lowered:
        return PROFILES["swift-test"]
    if any(token in lowered for token in ("build", "install", "release", "swift", "ghostty", "xcode")):
        return PROFILES["ghostty" if "ghostty" in lowered else "xcode"]
    if "companion" in lowered or "cargo" in lowered:
        return PROFILES["cargo"]
    if any(token in lowered for token in ("semgrep", "trivy", "osv", "gitleaks", "security")):
        return PROFILES["scan"]
    return None


def cost_for(goals):
    chosen = None
    for goal in goals:
        profile = profile_for(goal)
        if profile is None:
            continue
        if chosen is None or profile[0] > chosen[0] or (profile[0] == chosen[0] and profile[1] > chosen[1]):
            chosen = profile
    return chosen


def memory_text(mb):
    if abs(mb) >= 1024:
        return f"{mb / 1024:.1f} GB"
    return f"{mb:.0f} MB"


def thread_text(value):
    return f"{value:.1f} cpu threads"


def count_text(value):
    if abs(value - round(value)) < 0.05:
        return str(int(round(value)))
    return f"{value:.1f}"


def label_for(goals):
    return "make " + " ".join(goals)


def env_float(name, default):
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return float(raw)


def slot_directory():
    override = os.environ.get("EDITH_MAKE_GATE_DIR")
    if override:
        return Path(override)
    return Path.home() / ".cache" / "edith" / "make-slots"


def slot_table_text():
    if os.environ.get("EDITH_MAKE_GATE_DIR"):
        return str(slot_directory())
    return "~/.cache/edith/make-slots"


def log(line):
    print(f"{PREFIX}: {line}", file=sys.stderr, flush=True)


def release_slot():
    path = HELD_SLOT["path"]
    if path is None:
        return
    path.unlink(missing_ok=True)
    HELD_SLOT["path"] = None


def host_from_env():
    return {
        "cpus": float(os.environ["EDITH_MAKE_GATE_CPUS"]),
        "load": float(os.environ.get("EDITH_MAKE_GATE_LOAD", "0")),
        "mem_total_mb": float(os.environ.get("EDITH_MAKE_GATE_MEM_TOTAL_MB", "16384")),
        "mem_available_mb": float(os.environ.get("EDITH_MAKE_GATE_MEM_AVAILABLE_MB", "16384")),
        "pressure": os.environ.get("EDITH_MAKE_GATE_PRESSURE", "normal"),
        "uncertain": False,
    }


def darwin_host():
    total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)) // (1024 * 1024)
    vm = subprocess.check_output(["vm_stat"], text=True)
    page = 4096
    matched = re.search(r"page size of (\d+) bytes", vm)
    if matched:
        page = int(matched.group(1))
    pages = {}
    for line in vm.splitlines():
        found = re.match(r"(.+):\s+(\d+)\.", line)
        if found:
            pages[found.group(1).strip()] = int(found.group(2))
    available_pages = (
        pages.get("Pages free", 0)
        + pages.get("Pages inactive", 0)
        + pages.get("Pages speculative", 0)
    )
    available = available_pages * page // (1024 * 1024)
    level = subprocess.check_output(
        ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
        text=True,
    ).strip()
    pressure = {"1": "normal", "2": "warn", "4": "critical"}.get(level, "normal")
    return host_record(os.cpu_count() or 1, os.getloadavg()[0], total, available, pressure)


def linux_host():
    info = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        info[key] = float(value.strip().split()[0]) / 1024
    total = info["MemTotal"]
    available = info.get("MemAvailable", info.get("MemFree", 0.0))
    ratio = available / total if total else 1
    if ratio < 0.1:
        pressure = "critical"
    elif ratio < 0.2:
        pressure = "warn"
    else:
        pressure = "normal"
    return host_record(os.cpu_count() or 1, os.getloadavg()[0], total, available, pressure)


def host_record(cpus, load, total, available, pressure):
    if pressure not in PRESSURE_SCALE:
        pressure = "normal"
    return {
        "cpus": float(cpus),
        "load": float(load),
        "mem_total_mb": float(total),
        "mem_available_mb": float(available),
        "pressure": pressure,
        "uncertain": False,
    }


def host_snapshot():
    if os.environ.get("EDITH_MAKE_GATE_CPUS"):
        return host_from_env()
    try:
        if sys.platform == "darwin":
            return darwin_host()
        return linux_host()
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError):
        return {
            "cpus": float(os.cpu_count() or 1),
            "load": 0.0,
            "mem_total_mb": 16384.0,
            "mem_available_mb": 16384.0,
            "pressure": "normal",
            "uncertain": True,
        }


def parse_process_table(text):
    rows = {}
    children = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            cpu = float(parts[2])
            rss = int(float(parts[3]))
        except ValueError:
            continue
        rows[pid] = (ppid, cpu, rss)
        children.setdefault(ppid, []).append(pid)
    return rows, children


def process_table():
    for command in (
        ["ps", "-ax", "-o", "pid=,ppid=,pcpu=,rss="],
        ["ps", "-eo", "pid=,ppid=,pcpu=,rss="],
    ):
        try:
            output = subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            continue
        return parse_process_table(output)
    return {}, {}


def tree_usage(pid, rows, children):
    cpu = 0.0
    rss_kb = 0
    stack = [pid]
    seen = set()
    while stack:
        current = stack.pop()
        if current in seen or current not in rows:
            continue
        seen.add(current)
        _ppid, pcpu, rss = rows[current]
        cpu += pcpu / 100.0
        rss_kb += rss
        stack.extend(children.get(current, []))
    return cpu, rss_kb / 1024.0


def command_of(pid):
    try:
        output = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return output.strip()


def read_slots(directory):
    jobs = []
    if not directory.exists():
        return jobs
    for path in directory.glob("*.json"):
        try:
            payload = json.loads(path.read_text())
            pid = int(payload["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            path.unlink(missing_ok=True)
            continue
        if pid == os.getpid():
            continue
        if "make-resource-gate.py" not in command_of(pid):
            path.unlink(missing_ok=True)
            continue
        payload["pid"] = pid
        jobs.append(payload)
    return jobs


def attach_usage(jobs):
    rows, children = process_table()
    for job in jobs:
        threads, rss_mb = tree_usage(int(job["pid"]), rows, children)
        job["measured_threads"] = threads
        job["measured_rss_mb"] = rss_mb
    return jobs


def reservation(job, now, ramp):
    age = now - float(job.get("started", now))
    threads = float(job["threads"])
    memory = float(job["mem_mb"])
    if age >= ramp:
        threads *= 0.5
        memory *= 0.5
    measured_threads = float(job.get("measured_threads") or 0)
    measured_memory = float(job.get("measured_rss_mb") or 0)
    return max(0.0, threads - measured_threads), max(0.0, memory - measured_memory)


def budget(host, jobs, now, ramp):
    scale = PRESSURE_SCALE.get(host.get("pressure"), 1.0)
    pending_threads = 0.0
    pending_memory = 0.0
    measured_threads = 0.0
    for job in jobs:
        extra_threads, extra_memory = reservation(job, now, ramp)
        pending_threads += extra_threads
        pending_memory += extra_memory
        measured_threads += float(job.get("measured_threads") or 0)
    ungated_load = max(0.0, float(host["load"]) - measured_threads)
    headroom = max(2048.0, float(host["mem_total_mb"]) * 0.15) / scale
    cpu_left = max(0.0, float(host["cpus"]) - ungated_load - measured_threads) * scale - pending_threads
    mem_left = float(host["mem_available_mb"]) - headroom - pending_memory
    return cpu_left, mem_left


def job_line(job, now, ramp):
    age = now - float(job.get("started", now))
    measured = (
        f"measured {thread_text(float(job.get('measured_threads') or 0))} and "
        f"{memory_text(float(job.get('measured_rss_mb') or 0))}"
    )
    if age < ramp:
        phase = (
            f"reserving {thread_text(float(job['threads']))} and {memory_text(float(job['mem_mb']))} "
            f"for the first {count_text(ramp)}s of startup"
        )
    else:
        phase = (
            f"reserving at least half of {thread_text(float(job['threads']))} and "
            f"{memory_text(float(job['mem_mb']))} from its live usage"
        )
    folder = Path(job.get("cwd") or "").name
    place = f" in {folder}" if folder else ""
    return f"pid {job['pid']} `{job.get('label', 'make')}`{place}, {measured}, {phase}"


def decide(goals, host, jobs, now, ramp):
    running = len(jobs)
    chosen = cost_for(goals)
    if chosen is None:
        return {
            "action": "skip",
            "lines": [],
            "threads_left": None,
            "mem_left_mb": None,
            "need_threads": None,
            "need_mem_mb": None,
            "running": running,
            "profile": None,
            "over_budget": False,
        }
    need_threads, need_memory, profile = chosen
    cpu_left, mem_left = budget(host, jobs, now, ramp)
    fits = cpu_left + 0.05 >= need_threads and mem_left + 1 >= need_memory
    label = label_for(goals)
    base = {
        "threads_left": cpu_left,
        "mem_left_mb": mem_left,
        "need_threads": need_threads,
        "need_mem_mb": need_memory,
        "running": running,
        "profile": profile,
        "over_budget": not fits,
    }
    free_threads = thread_text(max(cpu_left, 0))
    free_memory = memory_text(max(mem_left, 0))
    want = f"{thread_text(need_threads)} and {memory_text(need_memory)} ({profile})"
    if running == 0:
        lines = [f"starting `{label}` now: no other gated make is running"]
        if host.get("uncertain"):
            lines.append("host cpu and memory could not be read, so this job starts on a generous budget")
        elif not fits:
            lines.append(
                f"the host is already tight: this job wants {want}, "
                f"and about {free_threads} and {free_memory} are free"
            )
        else:
            lines = [
                f"starting `{label}` now: it wants {want}, "
                f"and {free_threads} and {free_memory} are free"
            ]
        return {"action": "run", "lines": lines, **base}
    if fits:
        return {
            "action": "run",
            "lines": [
                f"starting `{label}` now: it wants {want}, "
                f"and {free_threads} and {free_memory} are free with {running} gated "
                f"{'make' if running == 1 else 'makes'} already running"
            ],
            **base,
        }
    lines = [
        f"waiting to start `{label}`",
        (
            f"reason: this job wants {want}, and the free budget is {free_threads} and {free_memory}. "
            f"load average covers other work on the machine. each running make also counts its live cpu, "
            f"plus the reserved cpu and memory it has not consumed yet"
        ),
        (
            f"host: {count_text(float(host['cpus']))} cpus, load {float(host['load']):.1f}, "
            f"{memory_text(float(host['mem_total_mb']))} memory, "
            f"{memory_text(float(host['mem_available_mb']))} available, pressure {host.get('pressure', 'normal')}"
        ),
    ]
    if host.get("uncertain"):
        lines.append("host cpu and memory could not be read; this decision uses a stand-in budget")
    lines.append(
        f"for the first {count_text(ramp)}s a running make keeps its full reservation, "
        "because a build uses little memory until compile actually starts. after that it keeps "
        "at least half of that reservation, and more when its live usage is higher"
    )
    lines.extend(f"running {job_line(job, now, ramp)}" for job in jobs)
    lines.append(f"pids and names are recorded in the shared slot table ({slot_table_text()})")
    return {"action": "wait", "lines": lines, **base}


def write_slot(directory, goals, chosen):
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        "pid": os.getpid(),
        "label": label_for(goals),
        "goals": goals,
        "threads": chosen[0],
        "mem_mb": chosen[1],
        "profile": chosen[2],
        "cwd": os.getcwd(),
        "started": time.time(),
    }
    target = directory / f"{os.getpid()}.json"
    temporary = directory / f".{os.getpid()}.json.tmp"
    temporary.write_text(json.dumps(payload))
    os.replace(temporary, target)
    HELD_SLOT["path"] = target
    return target


def locked_decision(directory, goals, ramp):
    directory.mkdir(parents=True, exist_ok=True)
    handle = (directory / ".lock").open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        jobs = attach_usage(read_slots(directory))
        decision = decide(goals, host_snapshot(), jobs, time.time(), ramp)
        if decision["action"] == "run":
            write_slot(directory, goals, cost_for(goals))
        return decision
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def acquire(goals):
    timeout = max(0.0, env_float("EDITH_MAKE_GATE_TIMEOUT", 300.0))
    interval = max(0.2, env_float("EDITH_MAKE_GATE_INTERVAL", 5.0))
    ramp = max(0.0, env_float("EDITH_MAKE_GATE_RAMP", 20.0))
    directory = slot_directory()
    started = time.monotonic()
    deadline = started + timeout
    announced = False
    last_detail = 0.0
    while True:
        decision = locked_decision(directory, goals, ramp)
        if decision["action"] == "run":
            waited = time.monotonic() - started
            if announced:
                log(f"starting `{label_for(goals)}` after waiting {waited:.0f}s")
            for line in decision["lines"]:
                log(line)
            return 0
        now = time.monotonic()
        remaining = deadline - now
        if remaining <= 0:
            log(f"stopped waiting after {timeout:.0f}s and did not start `{label_for(goals)}`")
            for line in decision["lines"]:
                log(line)
            return 1
        elapsed = now - started
        if not announced or elapsed - last_detail >= 30:
            for line in decision["lines"]:
                log(line)
            log(f"checking every {interval:.0f}s, giving up after {timeout:.0f}s")
            announced = True
            last_detail = elapsed
        else:
            running = decision["running"]
            noun = "gated make" if running == 1 else "gated makes"
            log(
                f"still waiting, {elapsed:.0f}s of {timeout:.0f}s: "
                f"{thread_text(max(decision['threads_left'], 0))} and "
                f"{memory_text(max(decision['mem_left_mb'], 0))} free, "
                f"need {thread_text(decision['need_threads'])} and {memory_text(decision['need_mem_mb'])}, "
                f"{running} {noun} running"
            )
        time.sleep(min(interval, remaining))


def run_command(command):
    env = os.environ.copy()
    env["EDITH_MAKE_GATE"] = "1"
    process = subprocess.Popen(command, env=env, start_new_session=True)

    def handle(signum, _frame):
        try:
            os.killpg(process.pid, signum)
        except OSError:
            pass
        release_slot()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)
    code = process.wait()
    if code < 0:
        return 128 + abs(code)
    return code


def run_exec(args):
    if not args or args[0] != "--goals" or "--" not in args:
        raise SystemExit("usage: make-resource-gate.py exec --goals <goal>... -- <command>")
    split = args.index("--")
    goals = args[1:split]
    command = args[split + 1 :]
    if not goals or not command:
        raise SystemExit("exec requires at least one goal and a command")
    chosen = cost_for(goals)
    if chosen is None:
        env = os.environ.copy()
        env["EDITH_MAKE_GATE"] = "1"
        try:
            os.execvpe(command[0], command, env)
        except FileNotFoundError:
            log(f"command not found: {command[0]}")
            return 127
    status = acquire(goals)
    if status != 0:
        return status
    code = 127
    try:
        code = run_command(command)
    except FileNotFoundError:
        log(f"command not found: {command[0]}")
        code = 127
    finally:
        release_slot()
    return code


def parse_decide(args):
    values = {}
    goals = None
    index = 0
    while index < len(args):
        key = args[index]
        if key == "--goals":
            goals = []
            index += 1
            while index < len(args) and not args[index].startswith("--"):
                goals.append(args[index])
                index += 1
            continue
        if key in {"--host-json", "--jobs-json", "--now", "--ramp"}:
            if index + 1 >= len(args):
                raise SystemExit(f"missing value for {key}")
            values[key] = args[index + 1]
            index += 2
            continue
        raise SystemExit(f"unknown decide argument {key}")
    if not goals or any(name not in values for name in ("--host-json", "--jobs-json", "--now", "--ramp")):
        raise SystemExit(
            "usage: make-resource-gate.py decide --goals <goal>... "
            "--host-json JSON --jobs-json JSON --now SECONDS --ramp SECONDS"
        )
    return (
        goals,
        json.loads(values["--host-json"]),
        json.loads(values["--jobs-json"]),
        float(values["--now"]),
        float(values["--ramp"]),
    )


def run_decide(args):
    goals, host, jobs, now, ramp = parse_decide(args)
    print(json.dumps(decide(goals, host, jobs, now, ramp)))
    return 0


def main(argv):
    if not argv or argv[0] not in {"decide", "exec"}:
        raise SystemExit("usage: make-resource-gate.py decide|exec ...")
    if argv[0] == "decide":
        return run_decide(argv[1:])
    return run_exec(argv[1:])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        log(str(error))
        release_slot()
        sys.exit(1)
