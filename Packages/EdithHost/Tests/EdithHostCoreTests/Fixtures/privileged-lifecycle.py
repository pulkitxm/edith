import argparse
import ctypes
import json
import os
import plistlib
import selectors
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ["flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved"]] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [(name, ctypes.c_uint32) for name in ["files", "group", "job", "device", "terminal", "nice"]] + [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def identity(pid):
    info = ProcessInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    assert library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
    return {"pid": pid, "generation": str(info.seconds) + "." + str(info.microseconds)}


def request(worker, operation, stop=None):
    token = str(uuid.uuid4())
    message = {"token": token, "operation": operation}
    if stop is not None:
        message["stop"] = stop
    worker.stdin.write(json.dumps(message).encode() + b"\n")
    worker.stdin.flush()
    selector = selectors.DefaultSelector()
    selector.register(worker.stdout, selectors.EVENT_READ)
    ready = selector.select(5)
    selector.close()
    assert ready, "Synthetic worker did not answer"
    line = worker.stdout.readline(65537)
    if not line:
        worker.wait(timeout=5)
        raise AssertionError(worker.stderr.read().decode(errors="replace")[:2048] or "Synthetic worker exited before response")
    response = json.loads(line)
    assert response["token"].lower() == token
    return response


def stop(worker, reason, retain=False):
    value = {"reason": reason, "owner": "lidAwake", "worker": identity(worker.pid), "parent": identity(os.getpid())}
    if retain:
        value["quitPolicy"] = {"reason": "applicationQuit", "restoreOnQuit": False, "host": identity(os.getpid())}
    return value


parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--bundle", required=True)
args = parser.parse_args()
assert os.geteuid() != 0
app = Path(args.app).resolve()
bundle = Path(args.bundle).resolve()
with (app / "Contents/Info.plist").open("rb") as stream:
    assert plistlib.load(stream)["CFBundleIdentifier"].startswith("com.pulkit.edith.dev.lifetime-")
with (bundle / "Contents/Info.plist").open("rb") as stream:
    assert plistlib.load(stream)["CFBundleIdentifier"] == "com.pulkit.edith.tests.lifetime-runtime"
for path in [app, bundle]:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(path)], check=True, capture_output=True)
workers = []
with tempfile.TemporaryDirectory(prefix="privileged-lifetime-") as directory:
    root = Path(directory).resolve()
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root), "EDITH_EXTENSION_FIXTURE_HOME": str(root)}
    callbacks = root / "restoration-callbacks.jsonl"

    def restored(pid):
        if not callbacks.exists():
            return False
        return any(json.loads(line)["pid"] == pid for line in callbacks.read_text().splitlines())

    def start():
        worker = subprocess.Popen([str(app / "Contents/MacOS/Edith"), "--extension-privileged-fixture", str(bundle)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        workers.append(worker)
        assert request(worker, "start").get("error") is None
        return worker

    try:
        retained = start()
        assert request(retained, "stop", stop(retained, "applicationQuit", True)).get("error") is None
        assert retained.wait(timeout=5) == 0
        assert not restored(retained.pid)
        forced = start()
        assert request(forced, "stop", stop(forced, "disable")).get("error") is None
        assert forced.wait(timeout=5) == 0 and restored(forced.pid)
        disconnected = start()
        disconnected.stdin.close()
        assert disconnected.wait(timeout=5) == 0 and restored(disconnected.pid)
        stale = start()
        forged = stop(stale, "applicationQuit", True)
        forged["worker"]["generation"] = "0.0"
        assert request(stale, "stop", forged).get("error") is not None
        assert stale.poll() is None
        stale.stdin.close()
        assert stale.wait(timeout=5) == 0 and restored(stale.pid)
        wrong_reason = start()
        assert request(wrong_reason, "stop", stop(wrong_reason, "update", True)).get("error") is not None
        wrong_reason.stdin.close()
        assert wrong_reason.wait(timeout=5) == 0 and restored(wrong_reason.pid)
        input_read, input_write = os.pipe()
        output_read, output_write = os.pipe()
        child_file = root / "owned-worker-pid"
        launcher = "import json,os,subprocess,sys,time,uuid; child=subprocess.Popen([sys.argv[1],'--extension-privileged-fixture',sys.argv[2]],stdin=int(sys.argv[3]),stdout=int(sys.argv[4]),stderr=subprocess.DEVNULL); os.write(int(sys.argv[5]),(json.dumps({'token':str(uuid.uuid4()),'operation':'start'})+'\\n').encode()); open(sys.argv[6],'w').write(str(child.pid)); time.sleep(0.5); os._exit(0)"
        orphan_identity = None
        parent = subprocess.Popen(["/usr/bin/python3", "-c", launcher, str(app / "Contents/MacOS/Edith"), str(bundle), str(input_read), str(output_write), str(input_write), str(child_file)], env=environment, pass_fds=(input_read, input_write, output_write))
        os.close(input_read)
        os.close(output_write)
        try:
            with os.fdopen(output_read, "rb", buffering=0) as stream:
                selector = selectors.DefaultSelector()
                selector.register(stream, selectors.EVENT_READ)
                assert selector.select(5), "Synthetic orphan did not start"
                selector.close()
                assert json.loads(stream.readline(65537)).get("error") is None
                pid = int(child_file.read_text())
                orphan_identity = identity(pid)
                assert parent.wait(timeout=5) == 0
                deadline = time.monotonic() + 5
                while not restored(pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert restored(pid), "Parent loss did not invoke restoration with stdin still held open"
                selector = selectors.DefaultSelector()
                selector.register(stream, selectors.EVENT_READ)
                assert selector.select(5), "Owned orphan worker did not exit"
                selector.close()
                assert stream.read(1) == b"", "Owned orphan worker did not exit"
        finally:
            os.close(input_write)
            if parent.poll() is None:
                parent.kill()
                parent.wait()
            if orphan_identity is not None:
                try:
                    if identity(orphan_identity["pid"]) == orphan_identity:
                        os.kill(orphan_identity["pid"], 9)
                except (AssertionError, ProcessLookupError):
                    pass
        print(json.dumps({"signedWorkerCases": 6, "confirmedQuitExited": True, "forcedStopRestoredCallback": True, "eofRestoredCallback": True, "staleWorkerRejected": True, "forcedReasonRetentionRejected": True, "parentExitWithOpenInputRestoredCallback": True, "operatingSystemActions": 0, "visibleWindows": 0}))
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.stdin.close()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait()
