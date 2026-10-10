import ctypes
import json
import os
import subprocess
import sys
import time
import uuid

class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ["flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved"]] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [(name, ctypes.c_uint32) for name in ["files", "group", "job", "device", "terminal", "nice"]] + [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def generation(pid):
    info = ProcessInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise RuntimeError("Missing process identity")
    return str(info.seconds) + "." + str(info.microseconds)


mode = sys.argv[1]
os.setpgid(0, 0)
if mode in ["child", "child-group", "child-reserved", "child-group-crash", "child-group-ignore-stop"]:
    if mode == "child-reserved":
        child = subprocess.Popen([sys.executable, "-c", "import os,time;time.sleep(0.25);os.setpgid(0,0);time.sleep(30)"])
    else:
        child = subprocess.Popen(["/bin/sleep", "30"], start_new_session=mode != "child")
    if mode != "child":
        print(json.dumps({"kind": "processGroup", "pid": child.pid, "generation": generation(child.pid), "registered": True}), flush=True)
    with open(sys.argv[2], "w") as stream:
        stream.write(str(child.pid))
prepare_count = 0
configuration = None
navigation_requests = {}

def navigate():
    event = {"kind": "navigation", "token": str(uuid.uuid4()).upper(), "extensionID": configuration["extensionID"], "version": configuration["version"]}
    if mode == "navigation-wrong-id":
        event["extensionID"] = "other"
    if mode == "navigation-wrong-version":
        event["version"] = "99.0.0"
    print(json.dumps(event), flush=True)
    return event

for line in sys.stdin:
    request = json.loads(line)
    operation = request["operation"]
    if operation == "navigationReply":
        if mode == "folder-choice":
            with open(sys.argv[2], "w") as stream:
                json.dump(request["navigation"], stream)
        original = navigation_requests.pop(request["token"], None)
        if original is not None:
            print(json.dumps({"token": original, "ok": request["navigation"]["ok"]}), flush=True)
        continue
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
    if operation == "show" and mode == "folder-choice":
        event = {"kind": "navigation", "token": str(uuid.uuid4()).upper(), "extensionID": configuration["extensionID"], "version": configuration["version"], "presentationID": str(uuid.uuid4()).upper(), "location": "settings", "section": "agentActivity", "folderChoice": True}
        navigation_requests[event["token"]] = request["token"]
        print(json.dumps(event), flush=True)
        continue
    if operation == "show" and mode.startswith("navigation"):
        event = navigate()
        if mode in ["navigation-ack", "navigation-rejected", "navigation-cancel", "navigation-disconnect"]:
            if mode == "navigation-disconnect":
                sys.exit(0)
            if mode == "navigation-cancel":
                event["kind"] = "navigationCancel"
                print(json.dumps(event), flush=True)
            else:
                navigation_requests[event["token"]] = request["token"]
                continue
    if operation == "prepareDisable" and mode == "navigation-disable":
        navigate()
    if mode == "quit-policy" and operation in ["prepareDisable", "prepareApplicationQuit", "stop"]:
        with open(sys.argv[2], "a") as stream:
            stream.write(json.dumps(request) + "\n")
    if operation == "prepareApplicationQuit" and mode == "reject-quit":
        response["ok"] = False
    if operation == "prepareDisable":
        prepare_count += 1
        if mode == "reject-disable-always" or (mode == "reject-disable-once" and prepare_count == 1):
            response["ok"] = False
            response["message"] = "Restore sleep settings and try again."
        if mode == "late-disable" and prepare_count == 1:
            time.sleep(0.3)
    if operation == "start":
        configuration = request["configuration"]
        if mode == "navigation-early":
            navigate()
        recovery = request["configuration"]["recoveryOnly"]
        if mode == "require-recovery" and not recovery:
            response["ok"] = False
        if mode == "require-normal" and recovery:
            response["ok"] = False
        if recovery != (os.environ.get("EDITH_EXTENSION_RECOVERY_ONLY") == "1"):
            response["ok"] = False
        response["version"] = request["configuration"]["version"]
        if mode == "wrong-version":
            response["version"] = "99.0.0"
    print(json.dumps(response), flush=True)
    if operation == "stop":
        break
