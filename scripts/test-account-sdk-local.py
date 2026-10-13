import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
OWNER_SPEC = importlib.util.spec_from_file_location("account_native_ownership", ROOT / "scripts/hosted-native-owner-tests.py")
OWNERSHIP = importlib.util.module_from_spec(OWNER_SPEC)
OWNER_SPEC.loader.exec_module(OWNERSHIP)
DRIVER_SPEC = importlib.util.spec_from_file_location("account_selected_swift", ROOT / "scripts/run-host-swift-testing.py")
DRIVERS = importlib.util.module_from_spec(DRIVER_SPEC)
DRIVER_SPEC.loader.exec_module(DRIVERS)
OUTPUT_BOUND = 16_777_216
GROUPS = {
    "Sources/EdithExtensionAccounts": ["ClaudeAccount.swift", "ClaudeAccountStorage.swift", "ClaudeSavedLogin.swift", "OwnedAccountFiles.swift"],
    "Tests/EdithExtensionAccountsTests": ["AccountSupportModelTests.swift", "AccountSupportSavedLoginTests.swift", "AccountSupportStorageTests.swift"],
}
MANIFEST = """// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "AccountContracts",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EdithExtensionAccounts", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EdithExtensionAccountsTests", dependencies: ["EdithExtensionAccounts"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
"""


class LocalOwnership(OWNERSHIP.BoundedOwnership):
    def __init__(self, leader, uid):
        self.private_failure_identities = []
        super().__init__(leader, uid)

    def observe_failure(self, pid, kind, current=None):
        if len(self.private_failure_identities) < 8:
            original = self.known.get(pid)
            seal = self.seals.get(pid)
            self.private_failure_identities.append({
                "pid": pid, "kind": kind,
                "current": list(current) if current is not None else None,
                "originalKnown": list(original) if original is not None else None,
                "originalSeal": list(seal) if seal is not None else None,
            })
        return super().observe_failure(pid, kind, current)


def private_directory(path):
    if path.is_symlink():
        raise ValueError("Local contract directory must not be a symlink")
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
        raise ValueError("Local contract directory must be owned")
    path.chmod(0o700)
    return path


def verify_source(path, root):
    for parent in [path, *path.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError("Account contract source must not contain symlinks")
    if not path.is_file():
        raise ValueError("Account contract source must be a regular file")


def private_file(path, flags):
    descriptor = os.open(path, flags | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        os.close(descriptor)
        raise ValueError("Local contract file must be private and owned")
    return descriptor


def write_private(path, data):
    descriptor = private_file(path, os.O_RDWR)
    with os.fdopen(descriptor, "r+b") as stream:
        if stream.read(len(data) + 1) == data:
            return
        stream.seek(0)
        stream.truncate(0)
        stream.write(data)


def prepare_package(root, package):
    digests = {}
    count = 0
    for group, names in GROUPS.items():
        source = root / "Packages/ExtensionSupport" / group
        if source.is_symlink() or sorted(path.name for path in source.glob("*.swift")) != sorted(names):
            raise ValueError("Account contract source inventory changed")
        destination = package / group
        private_directory(destination.parent)
        private_directory(destination)
        if any(path.name not in names for path in destination.iterdir()):
            raise ValueError("Unexpected local account contract source")
        for name in names:
            path = source / name
            verify_source(path, root)
            data = path.read_bytes()
            write_private(destination / name, data)
            digests[f"{group}/{name}"] = hashlib.sha256(data).hexdigest()
            if group.startswith("Tests/"):
                count += len(re.findall(rb"@Test\b", data))
    write_private(package / "Package.swift", MANIFEST.encode())
    if count == 0:
        raise ValueError("Account contract suite is empty")
    return digests, count


def environment(fixture, modules=None):
    result = {key: os.environ[key] for key in ["PATH", "DEVELOPER_DIR", "LANG", "LC_ALL"] if key in os.environ}
    for name in ["tmp", "cache", "config", "security", "modules", "Data", "ExtensionState"]:
        private_directory(fixture / name)
    private_directory(fixture / "Data/herdr")
    modules = modules or fixture / "modules"
    result.update({
        "HOME": str(fixture), "CFFIXED_USER_HOME": str(fixture), "TMPDIR": str(fixture / "tmp") + "/",
        "XDG_CACHE_HOME": str(fixture / "cache"), "XDG_CONFIG_HOME": str(fixture / "config"),
        "CLANG_MODULE_CACHE_PATH": str(modules), "SWIFTPM_MODULECACHE_OVERRIDE": str(modules),
        "EDITH_EXTENSION_DATA_ROOT": str(fixture / "Data/herdr"), "EDITH_EXTENSION_STATE_ROOT": str(fixture / "ExtensionState"),
        "EDITH_EXTENSION_ID": "herdr", "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.dev.accounts-contracts",
    })
    return result


def test_result(exit_status, output, expected):
    matches = re.findall(rb"Test run with (\d+) tests.*?passed", output)
    passed = int(matches[0]) if len(matches) == 1 else 0
    executed = passed > 0 or re.search(rb"\bTest (?!run\b)[^\r\n]+ started\.", output) is not None
    status = exit_status if exit_status >= 0 else 1
    if status == 0 and (len(matches) != 1 or passed != expected):
        status = 1
    return status, passed, executed


def verified_cleanup(cleanup):
    return (cleanup["reaped"] and cleanup["remainingOwnedProcesses"] == 0
            and cleanup["unverifiedOwnedProcesses"] == 0 and not cleanup["ownershipErrors"]
            and cleanup["pendingOwnedChildren"] == 0 and cleanup["naturalSurvivorCount"] == 0)


def bound_output(output):
    overflow = output.stat().st_size > OUTPUT_BOUND
    if overflow:
        with os.fdopen(private_file(output, os.O_RDWR), "r+b") as bounded:
            bounded.truncate(OUTPUT_BOUND)
    return overflow


def ownership_metadata(process, ownership=None):
    def identities(values):
        return [
            {"pid": value[0], "birthSeconds": value[1], "birthMicroseconds": value[2],
             "executable": value[3], "group": value[4]}
            for value in list(values)[:64]
        ]
    return {
        "leaderPID": process.pid,
        "ownerUID": os.getuid(),
        "knownProcesses": identities(getattr(ownership, "known", {}).values()),
        "rejectedProcesses": identities(getattr(ownership, "rejected", {}).values()),
        "originalSeals": [
            {"pid": value[0], "birthSeconds": value[1], "birthMicroseconds": value[2],
             "group": value[3]}
            for value in list(getattr(ownership, "seals", {}).values())[:64]
        ],
        "executableTransitions": [
            {"previous": list(row["previous"]), "current": list(row["current"])}
            for row in list(getattr(ownership, "transitions", []))[:1024]
        ],
        "privateFailureIdentities": list(getattr(ownership, "private_failure_identities", []))[:8],
        "ownershipFailureObservations": list(getattr(ownership, "failure_observations", []))[:8],
        "capturedSnapshotFailures": list(getattr(ownership, "captured_snapshot_failures", []))[:8],
    }


def run_owned(command, root, environment, output, process_factory=subprocess.Popen,
              ownership_factory=LocalOwnership, clock=time.monotonic, sleep=time.sleep,
              deadline=360, cadence=0.1):
    if (type(deadline) not in {int, float} or not math.isfinite(deadline)
            or not 0 < deadline <= OWNERSHIP.TEST_DEADLINE
            or type(cadence) not in {int, float} or not math.isfinite(cadence)
            or not 0 < cadence <= 0.5):
        raise ValueError("Invalid owned phase deadline or cadence")
    started = clock()
    timed_out = False
    overflow = False
    failure = None
    ownership = None
    with os.fdopen(private_file(output, os.O_RDWR), "w+b") as log:
        process = process_factory(command, cwd=root, env=environment, stdout=log,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        metadata_path = output.with_suffix(".process.json")
        try:
            write_private(metadata_path, (json.dumps(ownership_metadata(process)) + "\n").encode())
            ownership = ownership_factory(process.pid, os.getuid())
            write_private(metadata_path, (json.dumps(ownership_metadata(process, ownership)) + "\n").encode())
            while True:
                ownership.refresh()
                if ownership.errors:
                    raise RuntimeError("Owned process identity validation failed")
                overflow = output.stat().st_size > OUTPUT_BOUND
                timed_out = clock() - started >= deadline
                if process.poll() is not None or overflow or timed_out:
                    break
                sleep(cadence)
        except Exception as error:
            failure = type(error).__name__
        finally:
            if ownership is None:
                try:
                    process.wait(timeout=5)
                    reaped = True
                except subprocess.TimeoutExpired:
                    reaped = False
                cleanup = {"reaped": reaped, "naturalSurvivorCount": 0,
                           "remainingOwnedProcesses": 0 if reaped else 1,
                           "unverifiedOwnedProcesses": 1, "pendingOwnedChildren": 0,
                           "ownershipErrors": ["Owned leader admission failed"]}
            else:
                cleanup = OWNERSHIP.retire(process, ownership, clock, sleep)
    overflow = bound_output(output) or overflow
    code = 124 if timed_out else 1 if overflow or failure else process.returncode
    safe = verified_cleanup(cleanup)
    return {"exitCode": code if safe and code is not None else 1,
            "failure": failure, "timedOut": timed_out, "logBoundExceeded": overflow,
            "processMetadata": ownership_metadata(process, ownership),
            "cleanup": cleanup}


def run():
    os.umask(0o077)
    allowed = Path(os.environ["EDITH_LOCAL_CI_ROOT"])
    if sys.platform != "darwin" or not allowed.is_absolute() or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed):
        raise ValueError("Local account contracts require a macOS checkout inside EDITH_LOCAL_CI_ROOT")
    local = ROOT / "local"
    if local.is_symlink():
        raise ValueError("Local contract storage must not be a symlink")
    local.mkdir(exist_ok=True)
    storage = private_directory(local / "account-contracts")
    with os.fdopen(private_file(storage / "run.lock", os.O_RDWR), "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        package = private_directory(storage / "package")
        build = private_directory(storage / "build")
        modules = private_directory(storage / "modules")
        digests, count = prepare_package(ROOT, package)
        fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=storage))
        started = time.monotonic()
        selected_driver_validated = False
        try:
            driver = DRIVERS.SelectedSwiftDriver(os.environ["DEVELOPER_DIR"], entry="swift-test")
            swift = driver.validate()
            command = [str(swift), "--package-path", str(package), "--scratch-path", str(build), "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"), "--security-path", str(fixture / "security"), "--filter", "AccountSupport", "--build-system", "swiftbuild", "--no-parallel", "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path", "-Xswiftc", str(modules)]
            owned = run_owned(command, ROOT, environment(fixture, modules), fixture / "tests.log")
            try:
                driver.validate()
                selected_driver_validated = True
            except (ValueError, OSError) as error:
                owned["exitCode"] = 1
                owned["selectedDriverFailure"] = type(error).__name__
            owned["selectedDriverValidated"] = selected_driver_validated
            with (fixture / "tests.log").open("rb") as source:
                output = source.read(OUTPUT_BOUND)
            write_private(storage / "last.log", output)
            sys.stdout.buffer.write(output)
            status, passed, executed = test_result(owned["exitCode"], output, count)
            receipt = {"exit": status, "elapsedSeconds": time.monotonic() - started, "expectedTests": count, "passedTests": passed, "sourceSHA256": digests, "outputSHA256": hashlib.sha256(output).hexdigest(), "applicationExecution": False, "sdkTestsExecuted": executed, "isolatedAccountSDK": True, "ownership": owned}
            write_private(storage / "receipt.json", (json.dumps(receipt, indent=2) + "\n").encode())
            print(json.dumps(receipt), flush=True)
            return status if status >= 0 else 1
        finally:
            if ("owned" in locals() and "status" in locals() and status == 0
                    and selected_driver_validated and verified_cleanup(owned["cleanup"])):
                shutil.rmtree(fixture)


if __name__ == "__main__":
    raise SystemExit(run())
