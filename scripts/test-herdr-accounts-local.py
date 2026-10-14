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
SUITES = (
    "AgentLaunchArgumentsTests", "HerdrAccountOwnerParityTests", "HerdrAccountSelectionTests",
    "HerdrAccountShellTests", "HerdrAccountTests", "HerdrLaunchSettingsTests",
    "HerdrLimitsLoginDispatchTests", "HerdrLimitsLoginTests", "HerdrPeerLifecycleTests",
    "HerdrSessionFilterStoreTests", "HerdrSessionFilterTests", "HerdrSettingsTests", "HerdrWorkerTests",
)
MODULE_SUITES = {
    "HerdrExtensionTests": ("AgentLaunchArgumentsTests", "HerdrLaunchSettingsTests"),
    "HerdrUITests": tuple(suite for suite in SUITES if suite not in (
        "AgentLaunchArgumentsTests", "HerdrLaunchSettingsTests")),
}
FILTER = "^(?:" + "|".join(
    re.escape(module) + r"\.(?:" + "|".join(suites) + ")"
    for module, suites in MODULE_SUITES.items()
) + r")(?:/|$)"
HOSTED_METHODS = (
    "exactOriginalSettingsSectionsRenderProviderAndSessionsFormsOffscreen",
    "notificationSettingsRenderAtCompactRegularWidthsZoomAndColorSchemes",
)
SKIP = r"^HerdrUITests\.HerdrSettingsTests/(?:" + "|".join(HOSTED_METHODS) + r")(?:\(\))?(?:/|$)"


def source_inventory(root):
    methods = []
    pins = {}
    hosted = []
    for path in sorted((root / "Extensions/herdr/Tests").glob("*/*.swift")):
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
            if suite == "HerdrSettingsTests" and match.group(1) in HOSTED_METHODS:
                hosted.append(identity)
            else:
                methods.append(identity)
        if selected:
            pins[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
    if (set(identity.split("/")[0] for identity in methods) != set(SUITES)
            or len(methods) != len(set(methods)) or len(methods) != 91
            or set(hosted) != {"HerdrSettingsTests/" + method for method in HOSTED_METHODS}):
        raise ValueError("Local Herdr account selection changed")
    return {"methods": methods, "pendingHostedMethods": hosted, "sourceSHA256": pins}


def environment(fixture):
    result = RUNTIME.environment(fixture)
    result.update({
        "EDITH_TEST_NATIVE_CAPTURE": "0", "EDITH_EXTENSION_FIXTURE_HOME": str(fixture),
        "EDITH_SHARED_DEFAULTS_SUITE": "edith.herdr.accounts." + fixture.name,
    })
    return result


def command(swift, root, fixture, developer):
    return [str(swift), "--package-path", str(root / "Extensions/herdr"),
            "--scratch-path", str(root / "Extensions/herdr/.build"),
            "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"),
            "--security-path", str(fixture / "security"), "--disable-automatic-resolution",
            "--filter", FILTER, "--skip", SKIP, "--build-system", "native", "--no-parallel",
            "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-plugin-path", "-Xswiftc",
            str(Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")]


def test_result(exit_status, output):
    status, passed, executed = RUNTIME.test_result(exit_status, output, 91)
    summaries = re.findall(rb"Test run with (\d+) tests in (\d+) suites passed", output)
    if status == 0 and summaries != [(b"91", b"13")]:
        status = 1
    return status, passed, executed


def remove_previous_receipt(path):
    if path.exists() or path.is_symlink():
        descriptor = RUNTIME.private_file(path, os.O_RDWR)
        try:
            opened = os.fstat(descriptor)
            current = path.lstat()
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                raise ValueError("Local Herdr receipt changed before removal")
            path.unlink()
        finally:
            os.close(descriptor)


def run():
    os.umask(0o077)
    allowed = Path(os.environ["EDITH_LOCAL_CI_ROOT"])
    if (sys.platform != "darwin" or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed)):
        raise ValueError("Local Herdr accounts require an owned macOS checkout on EDITH_LOCAL_CI_ROOT")
    local = ROOT / "local"
    if local.is_symlink():
        raise ValueError("Local Herdr contract storage must not be a symlink")
    local.mkdir(exist_ok=True)
    storage = RUNTIME.private_directory(local / "herdr-account-contracts")
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
                "expectedMethods": 91, "expectedSuites": 13, "passedMethods": passed,
                "expectedExpandedInvocations": 116,
                "expandedInvocationsQualified": False,
                "herdrTestsExecuted": executed, "applicationExecution": False,
                "selectedDriverValidated": validated, "sourceInventory": sources,
                "outputSHA256": hashlib.sha256(output).hexdigest(), "ownership": owned,
            }
            RUNTIME.write_private(storage / "receipt.json", (json.dumps(receipt, indent=2) + "\n").encode())
            completed = True
            print(json.dumps({"exit": status, "passedMethods": passed,
                              "pendingHostedMethods": len(HOSTED_METHODS)}), flush=True)
            return status
        finally:
            if (completed and "owned" in locals() and "status" in locals() and status == 0
                    and validated and RUNTIME.verified_cleanup(owned["cleanup"])):
                shutil.rmtree(fixture)


if __name__ == "__main__":
    raise SystemExit(run())
