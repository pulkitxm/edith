import base64
import json
import os
import sys
import time

os.setpgid(0, 0)
mode = sys.argv[1]
prepared = 0
for line in sys.stdin:
    request = json.loads(line)
    operation = request["operation"]
    response = {"token": request["token"], "data": base64.b64encode(b"").decode()}
    if operation == "invoke":
        response["data"] = request["payload"]
    if operation == "prepareDisable":
        prepared += 1
        if mode == "reject-once" and prepared == 1:
            response = {"token": request["token"], "error": "Restore refused"}
        if mode == "late" and prepared == 1:
            time.sleep(0.3)
    if operation == "stop":
        if mode == "stop-without-response":
            os._exit(0)
        if mode == "stop-failure":
            os._exit(2)
    if operation == "prepareDisable" and mode == "prepare-without-response":
        os._exit(0)
    print(json.dumps(response), flush=True)
    if operation == "stop":
        break
