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
SUITES = {
    "TimeLapseTests": (
        "standardIsDefaultAndPreservesNormalSpeed", "libraryRejectsLinkedSessionsAndExternalMetadata",
        "invalidStandardFrameRatesAreRejected", "selectedSpeedControlsCaptureTimingAndStorage",
        "fiveHoursIsTwoMinutesOfPlayback", "audioCostUsesWallTime",
        "segmentRecoveryWindowIsAtMostFiveMinutes", "invalidAndNonFiniteIntervalsAreRejected",
        "dimensionsPreserveAspectWithoutUpscaling", "clockSkipsMissedIntervalsAfterSleepAndBackpressure",
        "sessionRoundTripsAndRejectsUnsafePaths", "duplicateSegmentsAndInvalidDurationsAreRejected",
    ),
    "TimeLapseRemoteUITests": (
        "originalRecorderStateKeepsUnsavedDraftAndUIShutdownDoesNotStopEngineRecording",
        "boundedSavedRecordingUsesOriginalRemoteExportAndExactQualityAndLeaf",
        "originalRemoteCancelWaitsForSavedExporterCallbackReturn",
    ),
}
PARAMETER_COUNTS = {"standardIsDefaultAndPreservesNormalSpeed": 2,
                    "selectedSpeedControlsCaptureTimingAndStorage": 6}
FILTER = r"(?:^|[./])(?:" + "|".join(SUITES) + r")/"


def source_inventory(root):
    methods = []
    pins = {}
    for suite, expected in SUITES.items():
        path = root / "Extensions/timeLapse/Tests" / (suite + ".swift")
        RUNTIME.verify_source(path, root)
        data = path.read_bytes()
        found = re.findall(rb"@Test\b(?:(?!@Test).)*?\bfunc\s+(\w+)\(", data, re.S)
        if tuple(value.decode() for value in found) != expected:
            raise ValueError("Local TimeLapse original selection changed")
        methods.extend(suite + "/" + value for value in expected)
    for prefix in ["Extensions/timeLapse", "Packages/ExtensionSupport", "Extensions/fixtureSupport"]:
        source = root / prefix
        if not source.is_dir() or source.is_symlink():
            raise ValueError("Local TimeLapse source root must be a directory")
        for path in sorted(source.rglob("*")):
            if any(part in {".build", ".swiftpm"} for part in path.relative_to(source).parts):
                continue
            if path.is_symlink():
                raise ValueError("Local TimeLapse source must not contain symlinks")
            if path.is_file():
                RUNTIME.verify_source(path, root)
                pins[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ["Makefile", "scripts/make-resource-gate.py", "scripts/test-time-lapse-local.py",
                 "scripts/test-time-lapse-local.test.py", "scripts/test-account-sdk-local.py",
                 "scripts/run-host-swift-testing.py", "scripts/hosted-native-owner-tests.py",
                 "scripts/hosted-host-tests/watchdog.py"]:
        path = root / name
        RUNTIME.verify_source(path, root)
        pins[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"methods": methods, "sourceSHA256": pins}


def environment(fixture):
    result = RUNTIME.environment(fixture)
    RUNTIME.private_directory(fixture / "Data/timeLapse")
    for name in ["xdg-data", "xdg-state", "xdg-runtime"]:
        RUNTIME.private_directory(fixture / name)
    result.update({
        "EDITH_TEST_NATIVE_CAPTURE": "0", "EDITH_EXTENSION_FIXTURE_HOME": str(fixture),
        "EDITH_EXTENSION_DATA_ROOT": str(fixture / "Data/timeLapse"), "EDITH_EXTENSION_ID": "timeLapse",
        "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.dev.time-lapse-contracts",
        "EDITH_SHARED_DEFAULTS_SUITE": "edith.timeLapse.local." + fixture.name,
        "XDG_DATA_HOME": str(fixture / "xdg-data"), "XDG_STATE_HOME": str(fixture / "xdg-state"),
        "XDG_RUNTIME_DIR": str(fixture / "xdg-runtime"),
    })
    return result


def command(swift, root, fixture, developer):
    return [str(swift), "--package-path", str(root / "Extensions/timeLapse"),
            "--scratch-path", str(root / "Extensions/timeLapse/.build"),
            "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"),
            "--security-path", str(fixture / "security"), "--disable-automatic-resolution",
            "--filter", FILTER, "--build-system", "native", "--no-parallel",
            "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-plugin-path", "-Xswiftc",
            str(Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")]


def test_result(exit_status, output):
    expected = {method for methods in SUITES.values() for method in methods}
    rows = re.findall(rb"\bTest (\w+)\([^\r\n]*\)(?: with ([1-9][0-9]*) test cases)? passed", output)
    passed = [name.decode() for name, count in rows]
    summaries = re.findall(rb"Test run with (\d+) tests in (\d+) suites passed", output)
    suites = re.findall(rb"\bSuite (\w+) passed", output)
    cases = re.findall(rb"Test case passing [^\r\n]+ to (\w+)\([^\r\n]*\) started", output)
    parameter_counts = {name.decode(): int(count) for name, count in rows if count}
    expanded = sum(int(count) if count else 1 for name, count in rows)
    valid = (len(passed) == len(expected) and set(passed) == expected
             and summaries == [(b"15", b"2")]
             and len(suites) == 2 and {name.decode() for name in suites} == set(SUITES)
             and parameter_counts == PARAMETER_COUNTS and expanded == 21
             and len(cases) == sum(PARAMETER_COUNTS.values())
             and all(cases.count(name.encode()) == count for name, count in PARAMETER_COUNTS.items()))
    status = exit_status if exit_status >= 0 else 1
    executed = bool(passed) or re.search(rb"\bTest \w+\([^\r\n]*\) started", output) is not None
    return (status if status or valid else 1), len(passed), expanded, executed


def remove_previous_receipt(path):
    if path.exists() or path.is_symlink():
        descriptor = RUNTIME.private_file(path, os.O_RDWR)
        try:
            opened = os.fstat(descriptor)
            current = path.lstat()
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                raise ValueError("Local TimeLapse receipt changed before removal")
            path.unlink()
        finally:
            os.close(descriptor)


def run():
    if sys.argv[1:]:
        raise ValueError("Unexpected local TimeLapse arguments")
    os.umask(0o077)
    allowed = Path(os.environ["EDITH_LOCAL_CI_ROOT"])
    if (sys.platform != "darwin" or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or ROOT.resolve(strict=True) != ROOT or not ROOT.is_relative_to(allowed)):
        raise ValueError("Local TimeLapse tests require an owned macOS checkout on EDITH_LOCAL_CI_ROOT")
    local = ROOT / "local"
    if local.is_symlink():
        raise ValueError("Local TimeLapse contract storage must not be a symlink")
    RUNTIME.private_directory(local)
    storage = RUNTIME.private_directory(local / "time-lapse-contracts")
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
            status, passed, expanded, executed = test_result(owned["exitCode"], output)
            if not RUNTIME.verified_cleanup(owned["cleanup"]) or source_inventory(ROOT) != sources:
                status = 1
            receipt = {
                "exit": status, "elapsedSeconds": time.monotonic() - started,
                "expectedMethods": 15, "expectedSuites": 2, "passedMethods": passed,
                "expectedExpandedInvocations": 21, "expandedInvocations": expanded,
                "expandedInvocationsQualified": status == 0 and executed,
                "timeLapseTestsExecuted": executed, "applicationExecution": False,
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
