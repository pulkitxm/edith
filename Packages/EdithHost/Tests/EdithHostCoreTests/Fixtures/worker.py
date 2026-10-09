import json
import os
import subprocess
import sys
import time

mode = sys.argv[1]
os.setpgid(0, 0)
if mode in ["child", "child-group", "child-reserved", "child-group-crash", "child-group-ignore-stop"]:
    if mode == "child-reserved":
        child = subprocess.Popen([sys.executable, "-c", "import os,time;time.sleep(0.25);os.setpgid(0,0);time.sleep(30)"])
    else:
        child = subprocess.Popen(["/bin/sleep", "30"], start_new_session=mode != "child")
    if mode != "child":
        print(json.dumps({"kind": "processGroup", "pid": child.pid, "registered": True}), flush=True)
    with open(sys.argv[2], "w") as stream:
        stream.write(str(child.pid))
prepare_count = 0
for line in sys.stdin:
    request = json.loads(line)
    operation = request["operation"]
    if mode in ["crash", "child-group-crash"]:
        sys.exit(4)
    if mode == "timeout":
        time.sleep(30)
    if mode == "malformed":
        print("x" * 70000, flush=True)
        continue
    if mode in ["ignore-stop", "child-group-ignore-stop"] and operation == "stop":
        time.sleep(30)
    response = {"token": request["token"], "ok": mode != "reject"}
    if operation == "prepareDisable":
        prepare_count += 1
        if mode == "reject-disable-once" and prepare_count == 1:
            response["ok"] = False
            response["message"] = "Restore sleep settings and try again."
        if mode == "late-disable" and prepare_count == 1:
            time.sleep(0.3)
    if operation == "start":
        response["version"] = request["configuration"]["version"]
        if mode == "wrong-version":
            response["version"] = "99.0.0"
    print(json.dumps(response), flush=True)
    if operation == "stop":
        break
