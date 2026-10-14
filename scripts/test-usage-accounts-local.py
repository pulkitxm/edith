import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("local_account_runtime", ROOT / "scripts/test-account-sdk-local.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)
BACKEND_SUITES = (
    "ClaudeLimitsLoginTests", "AccountQuotaCacheTests", "ClaudeAccountLimitsTests",
    "UsageSelectionProjectionTests",
)
SUITES = (*BACKEND_SUITES, "UsageAccountHeaderTests", "LimitsStatusItemTests", "UsageAccountProjectionTests")
METHOD_COUNTS = dict(zip(SUITES, (6, 6, 12, 2, 4, 9, 8)))
FILTER = r"(?:" + "|".join(SUITES) + r")/"
BACKUP_SUITE = "UsageBackupTests"
BACKUP_METHOD = "ownedBackupWhitelistNeverExportsOrRestoresSavedAccountFiles"
BACKUP_FILTER = r"^UsageExtensionTests\." + BACKUP_SUITE + "/" + BACKUP_METHOD + r"(?:\(\))?(?:/|$)"


def expected_counts(backup_boundary):
    if type(backup_boundary) is not bool:
        raise ValueError("Local Usage selection must be a closed boolean")
    return (1, 1, 1) if backup_boundary else (47, 7, 52)


def backup_boundary_requested(arguments):
    if arguments not in ([], ["--backup-boundary"]):
        raise ValueError("Local Usage accepts only its maintained backup-boundary selector")
    return bool(arguments)


def source_inventory(root, backup_boundary=False):
    expected, _, _ = expected_counts(backup_boundary)
    counts = {BACKUP_SUITE: 1} if backup_boundary else METHOD_COUNTS
    methods = []
    pins = {}
    for path in sorted((root / "Extensions/usage/Tests").rglob("*.swift")):
        RUNTIME.verify_source(path, root)
        data = path.read_bytes()
        text = data.decode()
        suites = list(re.finditer(r"@Suite(?:\([^\n]*\))?\s*(?:@MainActor\s*)?struct\s+(\w+)", text))
        selected = False
        for match in re.finditer(r"@Test(?:(?!@Test).)*?\bfunc\s+(\w+)\(", text, re.S):
            preceding = [suite for suite in suites if suite.start() < match.start()]
            if not preceding or preceding[-1].group(1) not in counts:
                continue
            if backup_boundary and match.group(1) != BACKUP_METHOD:
                continue
            suite = preceding[-1].group(1)
            selected = True
            identity = suite + "/" + match.group(1)
            methods.append(identity)
        if selected:
            pins[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
    if (set(identity.split("/")[0] for identity in methods) != set(counts)
            or len(methods) != expected or len(methods) != len(set(methods))
            or any(sum(identity.startswith(suite + "/") for identity in methods) != count
                   for suite, count in counts.items())
            or (backup_boundary and methods != [BACKUP_SUITE + "/" + BACKUP_METHOD])):
        raise ValueError("Local Usage account selection changed")
    return {"methods": methods, "sourceSHA256": pins}


def environment(fixture):
    result = RUNTIME.environment(fixture)
    RUNTIME.private_directory(fixture / "Data/usage")
    for name in ["xdg-data", "xdg-state", "xdg-runtime"]:
        RUNTIME.private_directory(fixture / name)
    result.update({
        "EDITH_TEST_NATIVE_CAPTURE": "0", "EDITH_EXTENSION_FIXTURE_HOME": str(fixture),
        "EDITH_EXTENSION_DATA_ROOT": str(fixture / "Data/usage"), "EDITH_EXTENSION_ID": "usage",
        "EDITH_SHARED_DEFAULTS_SUITE": "edith.usage.accounts." + fixture.name,
        "XDG_DATA_HOME": str(fixture / "xdg-data"), "XDG_STATE_HOME": str(fixture / "xdg-state"),
        "XDG_RUNTIME_DIR": str(fixture / "xdg-runtime"),
    })
    return result


def command(swift, root, fixture, developer, backup_boundary=False):
    expected_counts(backup_boundary)
    return [str(swift), "--package-path", str(root / "Extensions/usage"),
            "--scratch-path", str(root / "Extensions/usage/.build"),
            "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"),
            "--security-path", str(fixture / "security"), "--disable-automatic-resolution",
            "--filter", BACKUP_FILTER if backup_boundary else FILTER,
            "--build-system", "native", "--no-parallel",
            "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-plugin-path", "-Xswiftc",
            str(Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")]


def test_result(exit_status, output, backup_boundary=False):
    methods, suites, _ = expected_counts(backup_boundary)
    status, passed, executed = RUNTIME.test_result(exit_status, output, methods)
    summaries = re.findall(rb"Test run with (\d+) tests? in (\d+) suites? passed", output)
    if backup_boundary:
        status = exit_status if exit_status >= 0 else 1
        passed = int(summaries[0][0]) if len(summaries) == 1 else 0
    if status == 0 and summaries != [(str(methods).encode(), str(suites).encode())]:
        status = 1
    if backup_boundary and status == 0:
        names = re.findall(rb"^\xe2\x97\x87 Test (\w+)\([^\n]*\) started\.$", output, re.M)
        positives = re.findall(rb"^\xe2\x9c\x94 Test (\w+)\([^\n]*\) passed", output, re.M)
        suite_starts = re.findall(rb"^\xe2\x97\x87 Suite (\w+) started\.$", output, re.M)
        suite_passes = re.findall(rb"^\xe2\x9c\x94 Suite (\w+) passed", output, re.M)
        if (names != [BACKUP_METHOD.encode()] or positives != [BACKUP_METHOD.encode()]
                or suite_starts != [BACKUP_SUITE.encode()] or suite_passes != [BACKUP_SUITE.encode()]):
            status = 1
    return status, passed, executed


def remove_previous_receipt(path):
    if path.exists() or path.is_symlink():
        descriptor = RUNTIME.private_file(path, os.O_RDWR)
        try:
            opened = os.fstat(descriptor)
            current = path.lstat()
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                raise ValueError("Local Usage receipt changed before removal")
            path.unlink()
        finally:
            os.close(descriptor)


def run(backup_boundary=False):
    methods, suites, expanded = expected_counts(backup_boundary)
    os.umask(0o077)
    allowed = Path(os.environ["EDITH_LOCAL_CI_ROOT"])
    if (sys.platform != "darwin" or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed)):
        raise ValueError("Local Usage accounts require an owned macOS checkout on EDITH_LOCAL_CI_ROOT")
    local = ROOT / "local"
    if local.is_symlink():
        raise ValueError("Local Usage contract storage must not be a symlink")
    local.mkdir(exist_ok=True)
    storage = RUNTIME.private_directory(local / "usage-account-contracts")
    with os.fdopen(RUNTIME.private_file(storage / "run.lock", os.O_RDWR), "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        remove_previous_receipt(storage / "receipt.json")
        sources = source_inventory(ROOT, backup_boundary)
        fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=storage))
        started = time.monotonic()
        validated = False
        completed = False
        try:
            driver = RUNTIME.DRIVERS.SelectedSwiftDriver(os.environ["DEVELOPER_DIR"], entry="swift-test")
            owned = RUNTIME.run_owned(
                RUNTIME.DRIVERS.SelectedPackageArguments(
                    driver, command(driver.validate(), ROOT, fixture, os.environ["DEVELOPER_DIR"], backup_boundary)),
                ROOT, environment(fixture), fixture / "tests.log")
            try:
                driver.validate()
                validated = True
            except (ValueError, OSError) as error:
                owned["exitCode"] = 1
                owned["selectedDriverFailure"] = type(error).__name__
            output = (fixture / "tests.log").read_bytes()[:RUNTIME.OUTPUT_BOUND]
            RUNTIME.write_private(storage / "last.log", output)
            status, passed, executed = test_result(owned["exitCode"], output, backup_boundary)
            if not RUNTIME.verified_cleanup(owned["cleanup"]) or source_inventory(ROOT, backup_boundary) != sources:
                status = 1
            receipt = {
                "exit": status, "elapsedSeconds": time.monotonic() - started,
                "expectedMethods": methods, "expectedSuites": suites, "passedMethods": passed,
                "expectedExpandedInvocations": expanded,
                "expandedInvocationsQualified": backup_boundary and status == 0,
                "usageTestsExecuted": executed, "applicationExecution": False,
                "selectedDriverValidated": validated, "sourceInventory": sources,
                "outputSHA256": hashlib.sha256(output).hexdigest(), "ownership": owned,
            }
            RUNTIME.write_private(storage / "receipt.json", (json.dumps(receipt, indent=2) + "\n").encode())
            completed = True
            print(json.dumps({"exit": status, "passedMethods": passed}), flush=True)
            return status
        finally:
            if (completed and "owned" in locals() and "status" in locals() and status == 0
                    and validated and RUNTIME.verified_cleanup(owned["cleanup"])):
                shutil.rmtree(fixture)


if __name__ == "__main__":
    raise SystemExit(run(backup_boundary_requested(sys.argv[1:])))
