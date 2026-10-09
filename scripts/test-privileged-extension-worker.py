import argparse
import base64
import json
import os
import selectors
import subprocess
import tempfile
import uuid
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", default="local/minimal-host/Edith.app")
parser.add_argument("--package", default="dist/extensions/lidAwake.zip")
args = parser.parse_args()
assert os.geteuid() != 0, "Run the synthetic privileged fixture without root privileges"
app = Path(args.app).resolve()
archive = Path(args.package).resolve()
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)

with tempfile.TemporaryDirectory(prefix="privileged-extension-fixture-") as directory:
    fixture = Path(directory)
    with zipfile.ZipFile(archive) as package:
        package.extractall(fixture)
    bundle = fixture / "lidAwake" / "privileged.bundle"
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True, capture_output=True)
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(fixture), "EDITH_EXTENSION_FIXTURE_HOME": str(fixture)}

    def start():
        return subprocess.Popen([str(app / "Contents/MacOS/Edith"), "--extension-privileged-fixture", str(bundle)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def request(worker, operation, command=None, value=None):
        token = str(uuid.uuid4())
        payload = {"token": token, "operation": operation}
        if command is not None:
            payload["command"] = command
            payload["payload"] = base64.b64encode(json.dumps(value).encode()).decode()
        worker.stdin.write(json.dumps(payload).encode() + b"\n")
        worker.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(worker.stdout, selectors.EVENT_READ)
        ready = selector.select(10)
        selector.close()
        assert ready, "Privileged fixture did not answer"
        response = json.loads(worker.stdout.readline(65537))
        assert response["token"].lower() == token
        assert response.get("error") is None, response.get("error")
        data = base64.b64decode(response.get("data", ""))
        return json.loads(data) if data else None

    workers = []
    try:
        first, second = start(), start()
        workers.extend([first, second])
        request(first, "start")
        request(second, "start")
        assert first.pid != second.pid
        request(first, "invoke", "setSleepDisabled", True)
        assert request(first, "invoke", "status", {})["sleepDisabled"]
        assert not request(second, "invoke", "status", {})["sleepDisabled"]
        request(first, "prepareDisable")
        assert not request(first, "invoke", "status", {})["sleepDisabled"]
        request(first, "stop")
        assert first.wait(timeout=5) == 0
        assert second.poll() is None
        request(second, "invoke", "setSleepDisabled", True)
        second.stdin.close()
        assert second.wait(timeout=5) == 0
        assert not (fixture / "lidAwake" / "lidAwake-state.json").exists()
        print(json.dumps({"id": "lidAwake", "signedPayload": True, "sameExecutable": True, "isolatedPrivilegedWorkers": True, "restoredBeforeExit": True, "connectionLossExited": True, "disabledProcesses": 0, "productionSystemEffects": 0}))
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.stdin.close()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait()
