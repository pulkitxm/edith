import json
import sys
import time

mode = sys.argv[1]
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
