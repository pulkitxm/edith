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


def source_inventory(root):
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
            if not preceding or preceding[-1].group(1) not in SUITES:
                continue
            suite = preceding[-1].group(1)
            selected = True
            identity = suite + "/" + match.group(1)
            methods.append(identity)
        if selected:
            pins[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
    if (set(identity.split("/")[0] for identity in methods) != set(SUITES)
            or len(methods) != len(set(methods))
            or any(sum(identity.startswith(suite + "/") for identity in methods) != count
                   for suite, count in METHOD_COUNTS.items())):
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


def command(swift, root, fixture, developer):
    return [str(swift), "--package-path", str(root / "Extensions/usage"),
            "--scratch-path", str(root / "Extensions/usage/.build"),
            "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"),
            "--security-path", str(fixture / "security"), "--disable-automatic-resolution",
            "--filter", FILTER, "--build-system", "native", "--no-parallel",
            "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-plugin-path", "-Xswiftc",
            str(Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")]


def test_result(exit_status, output):
    status, passed, executed = RUNTIME.test_result(exit_status, output, 47)
    summaries = re.findall(rb"Test run with (\d+) tests in (\d+) suites passed", output)
    if status == 0 and summaries != [(b"47", b"7")]:
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


def run():
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
        sources = source_inventory(ROOT)
        fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=storage))
        started = time.monotonic()
        validated = False
        completed = False
        try:
            driver = RUNTIME.DRIVERS.SelectedSwiftDriver(os.environ["DEVELOPER_DIR"], entry="swift-test")
            owned = RUNTIME.run_owned(
                RUNTIME.DRIVERS.SelectedPackageArguments(
                    driver, command(driver.validate(), ROOT, fixture, os.environ["DEVELOPER_DIR"])),
                ROOT, environment(fixture), fixture / "tests.log")
            try:
                driver.validate()
                validated = True
            except (ValueError, OSError) as error:
                owned["exitCode"] = 1
                owned["selectedDriverFailure"] = type(error).__name__
            output = (fixture / "tests.log").read_bytes()[:RUNTIME.OUTPUT_BOUND]
            RUNTIME.write_private(storage / "last.log", output)
            status, passed, executed = test_result(owned["exitCode"], output)
            if not RUNTIME.verified_cleanup(owned["cleanup"]) or source_inventory(ROOT) != sources:
                status = 1
            receipt = {
                "exit": status, "elapsedSeconds": time.monotonic() - started,
                "expectedMethods": 47, "expectedSuites": 7, "passedMethods": passed,
                "expectedExpandedInvocations": 52,
                "expandedInvocationsQualified": False,
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
    raise SystemExit(run())
