import json
import os
import subprocess
import sys
import time

mode = sys.argv[1]
os.setpgid(0, 0)
if mode == "child":
    child = subprocess.Popen(["/bin/sleep", "30"])
    with open(sys.argv[2], "w") as stream:
        stream.write(str(child.pid))
for line in sys.stdin:
    request = json.loads(line)
    operation = request["operation"]
    if mode == "crash":
        sys.exit(4)
    if mode == "timeout":
        time.sleep(30)
    if mode == "malformed":
        print("x" * 70000, flush=True)
        continue
    if mode == "ignore-stop" and operation == "stop":
        time.sleep(30)
    response = {"token": request["token"], "ok": mode != "reject"}
    if operation == "start":
        response["version"] = request["configuration"]["version"]
        if mode == "wrong-version":
            response["version"] = "99.0.0"
    print(json.dumps(response), flush=True)
    if operation == "stop":
        break
