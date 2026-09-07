import base64
import datetime
import json
import os
import pathlib
import plistlib
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from edith_test_environment import isolated_test_environment, test_build_directory

client_source = r'''
import Darwin
import Foundation

@objc protocol EdithAgentXPC {
    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void)
    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void)
    func subscribe(topic: String, reply: @escaping (String?) -> Void)
    func unsubscribe(topic: String, reply: @escaping (String?) -> Void)
    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void)
}

@objc protocol EdithAgentSubscriberXPC {
    func topicChanged(topic: String, payload: Data)
}

final class Reply: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var data: Data?
    var failure: String?
    func finish(_ data: Data?, _ failure: String?) {
        lock.lock()
        self.data = data
        self.failure = failure
        lock.unlock()
        semaphore.signal()
    }
}

final class Receiver: NSObject, EdithAgentSubscriberXPC {
    let lock = NSLock()
    var values: [Data] = []
    func topicChanged(topic: String, payload: Data) {
        lock.lock()
        values.append(payload)
        lock.unlock()
    }
    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

let arguments = CommandLine.arguments
let connection = NSXPCConnection(machServiceName: arguments[1])
connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
connection.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
let receiver = Receiver()
connection.exportedObject = receiver
connection.resume()

func request(_ body: (EdithAgentXPC, @escaping (Data?, String?) -> Void) -> Void) throws -> Data {
    let reply = Reply()
    let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish(nil, $0.localizedDescription) }
    guard let remote = proxy as? EdithAgentXPC else {
        throw NSError(domain: "Fixture", code: 1)
    }
    body(remote, reply.finish)
    guard reply.semaphore.wait(timeout: .now() + 15) == .success else {
        throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "XPC reply timed out."])
    }
    if let failure = reply.failure {
        throw NSError(domain: "Fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: failure])
    }
    return reply.data ?? Data()
}

do {
    _ = try request { $0.handshake(peerVersion: 1, reply: $1) }
    let result: Data
    if arguments[2] == "watch" {
        let message = try JSONSerialization.data(withJSONObject: ["channel": arguments[3], "body": ""])
        _ = try request { $0.perform(operation: "bus.subscribe", payload: message, reply: $1) }
        Thread.sleep(forTimeInterval: Double(arguments[4]) ?? 3)
        _ = try request { $0.perform(operation: "bus.unsubscribe", payload: message, reply: $1) }
        result = try JSONSerialization.data(withJSONObject: receiver.snapshot().map {
            try JSONSerialization.jsonObject(with: $0)
        })
    } else {
        let payload = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        result = try request { $0.perform(operation: arguments[2], payload: payload, reply: $1) }
    }
    FileHandle.standardOutput.write(result)
    connection.invalidate()
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    connection.invalidate()
    exit(1)
}
'''

repo = pathlib.Path(__file__).resolve().parents[1]
build = test_build_directory(repo)
root = pathlib.Path(tempfile.mkdtemp(prefix="emach-", dir="/tmp"))
label = "com.pulkit.edith.machine-test." + uuid.uuid4().hex
suite = label + ".defaults"
env = dict(isolated_test_environment(root, label), EDITH_AGENT_BUILD="machine-e2e")
results = []
booted = False
sshd = None
writer = None
remote_child = None
other_child = None
active_tasks = []


def call(arguments, timeout=20, check=True):
    result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(arguments) + ": " + result.stderr + result.stdout)
    return result


def invoke(operation, payload):
    path = root / ("request-" + uuid.uuid4().hex + ".json")
    path.write_text(json.dumps(payload))
    try:
        output = call([str(root / "client"), label, operation, str(path)]).stdout
        return json.loads(output) if output else None
    finally:
        path.unlink(missing_ok=True)


def wait_for(action, predicate, timeout=20):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = action()
        if predicate(latest):
            return latest
        time.sleep(0.05)
    raise AssertionError("Timed out: " + repr(latest))


def submit(operation, payload):
    identifier = str(uuid.uuid4()).upper()
    receipt = invoke("task.submit", dict(id=identifier, operation=operation, title="Machine fixture",
        payload=base64.b64encode(json.dumps(payload).encode()).decode()))
    active_tasks.append(identifier)
    return receipt["id"]


def status(identifier):
    return invoke("task.status", dict(id=identifier))


def finish(identifier, expected="succeeded"):
    result = wait_for(lambda: status(identifier), lambda item: item["snapshot"]["state"] in
        ["succeeded", "failed", "cancelled", "interrupted"])
    assert result["snapshot"]["state"] == expected, result
    active_tasks.remove(identifier)
    return result


def record(name, **data):
    result = dict(test=name, passed=True, **data)
    results.append(result)
    print(json.dumps(result), flush=True)


def process_running(pid):
    state = call(["/bin/ps", "-p", str(pid), "-o", "stat="], check=False)
    return state.returncode == 0 and not state.stdout.strip().startswith("Z")


try:
    (root / "client.swift").write_text(client_source)
    call(["/usr/bin/swiftc", str(root / "client.swift"), "-o", str(root / "client")], timeout=60)
    shutil.copy2(build / "edithd", root / "edithd")
    shutil.copytree(build / "Edith_EdithKit.bundle",
        root / "Edith_EdithKit.bundle")
    for name, identity in [("client", "ed"), ("edithd", "com.pulkit.edith.agent")]:
        call(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identity, str(root / name)])
    for name in ["host", "key"]:
        call(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)])
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    (root / "sshd_config").write_text("\n".join([
        "Port " + str(port), "ListenAddress 127.0.0.1", "HostKey " + str(root / "host"),
        "PidFile " + str(root / "sshd.pid"), "AuthorizedKeysFile " + str(root / "key.pub"),
        "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no",
        "StrictModes no", "LogLevel ERROR", "PermitRootLogin no", "AllowTcpForwarding no",
        "PermitTTY no", "UseDNS no", "Subsystem sftp internal-sftp", ""]))
    with (root / "sshd.log").open("w") as log:
        sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    machine = dict(id=str(uuid.uuid4()).upper(), name="Isolated SSH fixture", host="127.0.0.1",
        port=port, username=pwd.getpwuid(os.getuid()).pw_name,
        auth={"keyFile": dict(path=str(root / "key"), hasPassphrase=False)}, source={"manual": {}},
        sshClipboardEnabled=False, createdAt=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    machine_directory = root / "data/machines"
    machine_directory.mkdir(parents=True)
    (machine_directory / "machines.json").write_text(json.dumps([machine]))
    for key in ["suiteAgentsEnabled", "suiteMaintenanceEnabled", "suiteSystemEnabled",
                "suiteDeskEnabled", "suiteMediaEnabled", "suiteDataEnabled", "icloudBackup"]:
        call(["/usr/bin/defaults", "write", suite, key, "-bool", "false"])
    plist = root / "agent.plist"
    plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(root / "edithd")],
        MachServices={label: True}, KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: env[key] for key in env if key.startswith("EDITH_")},
        StandardOutPath=str(root / "stdout.log"), StandardErrorPath=str(root / "stderr.log"))))
    call(["/bin/launchctl", "bootstrap", "gui/" + str(os.getuid()), str(plist)])
    booted = True
    record("01 isolated launchd daemon and loopback SSH server", sshPort=port)

    binary = bytes(range(256)) * 2048
    request = dict(machine=machine, command="cat; printf diagnostics >&2", timeout=15,
        standardInput=base64.b64encode(binary).decode())
    command = finish(submit("machine.command", request))
    output = json.loads(base64.b64decode(command["result"]))
    assert base64.b64decode(output["stdout"]) == binary
    assert base64.b64decode(output["stderr"]) == b"diagnostics"
    record("02 daemon SSH command preserves binary stdin and output", bytes=len(binary))

    source = root / "source, with spaces.bin"
    destination = root / "remote, with spaces.bin"
    downloaded = root / "download, with spaces.bin"
    source.write_bytes(binary)
    upload = dict(machine=machine, direction="upload", localURL=source.as_uri(),
        remotePath=str(destination), timeout=20, replacesExisting=False)
    finish(submit("machine.transfer", upload))
    assert destination.read_bytes() == binary
    record("03 daemon upload publishes a binary file atomically", bytes=len(binary))
    download = dict(machine=machine, direction="download", localURL=downloaded.as_uri(),
        remotePath=str(destination), timeout=20)
    downloaded.write_bytes(b"old download")
    finish(submit("machine.transfer", download))
    assert downloaded.read_bytes() == binary
    record("04 daemon download replaces its destination only after success", bytes=len(binary))

    source.write_bytes(b"must not replace existing data")
    finish(submit("machine.transfer", upload), expected="failed")
    assert destination.read_bytes() == binary
    assert not list(root.glob("remote, with spaces.bin.edith*"))
    record("05 failed remote publication preserves the destination")

    samples = json.loads(call([str(root / "client"), label, "watch",
        "machine.metrics." + machine["id"], "4"], timeout=20).stdout)
    assert any(item.get("sample") is not None for item in samples), samples
    def metrics_job():
        return next(job for job in invoke("agent.jobs", None)
                    if job["descriptor"]["id"] == "machines.metrics")
    previous_runs = metrics_job()["runCount"]
    invoke("agent.run", "machines.metrics")
    completed_job = wait_for(metrics_job, lambda job: job["runCount"] > previous_runs
                             and job["phase"] != "running")
    assert completed_job.get("lastError") is None, completed_job
    record("06 daemon metrics stream and registered refresh job both succeed",
           snapshots=len(samples), completedRuns=completed_job["runCount"])

    cancel_command = dict(machine=machine,
        command="sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait", timeout=40)
    identifier = submit("machine.command", cancel_command)
    running = wait_for(lambda: status(identifier), lambda item: bool(item["output"]))
    remote_child = int(running["output"][0]["text"].strip())
    other_identifier = submit("machine.command", cancel_command)
    other_running = wait_for(lambda: status(other_identifier), lambda item: bool(item["output"]))
    other_child = int(other_running["output"][0]["text"].strip())
    invoke("task.cancel", dict(id=identifier))
    finish(identifier, expected="cancelled")
    wait_for(lambda: process_running(remote_child), lambda running: not running, timeout=5)
    remote_child = None
    assert process_running(other_child)
    assert status(other_identifier)["snapshot"]["state"] == "running"
    invoke("task.cancel", dict(id=other_identifier))
    finish(other_identifier, expected="cancelled")
    wait_for(lambda: process_running(other_child), lambda running: not running, timeout=5)
    other_child = None
    record("07 SSH cancellation terminates its child and preserves another task")

    identifier = submit("machine.command", dict(cancel_command, timeout=1))
    running = wait_for(lambda: status(identifier), lambda item: bool(item["output"]))
    remote_child = int(running["output"][0]["text"].strip())
    result = finish(identifier, expected="failed")
    assert result["snapshot"]["failureCode"] == "timedOut"
    wait_for(lambda: process_running(remote_child), lambda running: not running, timeout=5)
    remote_child = None
    record("08 SSH timeout also terminates remote children")

    fifo = root / "slow source"
    os.mkfifo(fifo)
    protected = root / "protected destination"
    protected.write_bytes(b"original destination")
    writer = subprocess.Popen([sys.executable, "-c",
        "import pathlib,sys,time; f=pathlib.Path(sys.argv[1]).open('wb', buffering=0); f.write(b'x'*131072); time.sleep(30)", str(fifo)])
    identifier = submit("machine.transfer", dict(machine=machine, direction="download",
        localURL=protected.as_uri(), remotePath=str(fifo), timeout=40))
    wait_for(lambda: list(root.glob(".edith-transfer-*")), lambda files: bool(files) and files[0].stat().st_size > 0)
    invoke("task.cancel", dict(id=identifier))
    finish(identifier, expected="cancelled")
    assert protected.read_bytes() == b"original destination"
    assert not list(root.glob(".edith-transfer-*"))
    record("09 cancelled transfer removes staging and preserves the destination")

    source.write_bytes(binary)
    whole_local = root / "whole local, binary.bin"
    transfer_plan = dict(plan=dict(destination=str(root), items=[dict(sourcePath=str(source),
        destinationPath=str(whole_local), replacesExisting=False)], skipped=[]),
        source={"local": {}}, destination={"local": {}}, confirmsReplacement=False, moving=False)
    finish(submit("machine.files.transfer", transfer_plan))
    assert whole_local.read_bytes() == binary
    record("10 whole local transfer plan completes in one daemon task", bytes=len(binary))

    whole_remote = root / "whole remote, binary.bin"
    transfer_plan["plan"]["items"][0]["destinationPath"] = str(whole_remote)
    transfer_plan["destination"] = {"remote": {"_0": machine}}
    finish(submit("machine.files.transfer", transfer_plan))
    assert whole_remote.read_bytes() == binary
    record("11 daemon completes local staging and remote publication after client exit")

    whole_moved = root / "whole moved, binary.bin"
    transfer_plan["plan"]["items"][0] = dict(sourcePath=str(whole_remote),
        destinationPath=str(whole_moved), replacesExisting=False)
    transfer_plan["source"] = {"remote": {"_0": machine}}
    transfer_plan["destination"] = {"local": {}}
    transfer_plan["moving"] = True
    finish(submit("machine.files.transfer", transfer_plan))
    assert whole_moved.read_bytes() == binary
    assert not whole_remote.exists()
    record("12 remote move publishes locally before removing its source")
finally:
    for identifier in active_tasks:
        try:
            invoke("task.cancel", dict(id=identifier))
        except Exception:
            pass
    if remote_child is not None and process_running(remote_child):
        os.kill(remote_child, signal.SIGTERM)
    if other_child is not None and process_running(other_child):
        os.kill(other_child, signal.SIGTERM)
    if writer is not None:
        writer.terminate()
        writer.wait(timeout=5)
    for control in (root / "data/machines/sockets").glob("*.sk"):
        call(["/usr/bin/ssh", "-S", str(control), "-O", "exit", "127.0.0.1"], check=False)
    if booted:
        call(["/bin/launchctl", "bootout", "gui/" + str(os.getuid()) + "/" + label], check=False)
    if sshd is not None:
        sshd.terminate()
        sshd.wait(timeout=5)
    call(["/usr/bin/defaults", "delete", suite], check=False)
    for name in ["key", "key.pub", "host", "host.pub"]:
        (root / name).unlink(missing_ok=True)
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Artifacts: " + str(root), flush=True)
