import datetime
import hashlib
import json
import os
import pathlib
import sys
import threading
import time
import uuid

root = pathlib.Path(sys.argv[1])
state = {"phase": "idle", "runCount": 0, "lastRun": None, "lastDuration": None, "lastError": None}
events = []
worker = None
cancel = threading.Event()
lock = threading.Lock()

def event(message):
    events.append({"id": str(uuid.uuid4()), "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"), "level": "info", "category": "jobs", "name": "usage.refresh", "message": message})

def work():
    started = time.monotonic()
    digest = hashlib.sha256((root / "input").read_bytes()).hexdigest()
    (root / "digest").write_text(digest)
    cancel.wait(10)
    with lock:
        state["phase"] = "idle"
        state["lastDuration"] = time.monotonic() - started
        event("Cancelled." if cancel.is_set() else "Completed.")

def report():
    tool = (root / "tool").is_file() and os.access(root / "tool", os.X_OK)
    permission = (root / "permission").read_text() == "granted"
    checks = [
        {"id": "tool", "title": "Required tool", "status": "passed" if tool else "failed", "detail": "Synthetic owned tool is executable." if tool else "Required tool is missing.", "runtimePhase": "installed", "recoveryCommand": None if tool else "ed extensions setup usage --install-tools"},
        {"id": "permission", "title": "Required permission", "status": "passed" if permission else "failed", "detail": "Synthetic fixture grant is present." if permission else "Required permission is missing.", "recoveryCommand": None if permission else "ed permissions request accessibility"},
    ]
    issues = [{"id": c["id"], "title": c["title"], "detail": c["detail"], "recoveryCommand": c["recoveryCommand"]} for c in checks if c["status"] == "failed"]
    return {"owner": "usage", "id": "usage", "title": "Usage", "verified": not issues,
        "state": {"extensionID": "usage", "phase": "ready" if not issues else "needsSetup", "runtimePhase": "installed", "summary": "Ready." if not issues else "Required tool or permission is missing.", "issues": issues},
        "checks": checks, "remediation": [i["recoveryCommand"] for i in issues]}

for line in sys.stdin:
    request = json.loads(line)
    operation = request["operation"]
    payload = request.get("payload", {})
    with (root / "trace").open("a") as trace:
        trace.write(json.dumps(request) + "\n")
    if operation == "jobs":
        with lock:
            result = {"owner": "usage", "jobs": [{"descriptor": {"id": "usage.refresh", "title": "Usage cost refresh", "trigger": "fileSystem", "topic": "usage", "cadence": {"ambient": 900, "live": None}, "power": "any", "abilityID": "usage"}, **state, "subscribers": 0}]}
    elif operation == "run":
        accepted = worker is None or not worker.is_alive()
        if accepted:
            cancel.clear()
            state.update(phase="running", runCount=state["runCount"] + 1, lastRun=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"))
            event("Started.")
            worker = threading.Thread(target=work)
            worker.start()
        result = {"owner": "usage", "job": payload["job"], "accepted": accepted}
    elif operation == "cancel":
        accepted = worker is not None and worker.is_alive()
        if accepted:
            cancel.set()
            worker.join()
        result = {"owner": "usage", "job": payload["job"], "accepted": accepted}
    elif operation == "events":
        result = {"owner": "usage", "events": events}
    elif operation == "logs":
        result = {"owner": "usage", "lines": [e["date"] + " [info] usage.refresh: " + e["message"] for e in events]}
    elif operation == "inspect":
        result = report()
    elif operation == "setup":
        planned = [] if (root / "tool").exists() else ["synthetic-tool"]
        installed = []
        if payload["installTools"] and not payload["dryRun"] and planned:
            (root / "tool").write_text("#!/bin/sh\nprintf synthetic\\n\n")
            (root / "tool").chmod(0o700)
            installed = planned
        result = {"owner": "usage", "id": "usage", "dryRun": payload["dryRun"], "changed": False, "plannedTools": planned, "installedTools": installed, "installFailures": [], "report": report()}
    else:
        raise RuntimeError("Unknown controlled operation")
    print(json.dumps(result), flush=True)
cancel.set()
if worker is not None:
    worker.join()
