import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("account_sdk_local", Path(__file__).with_name("test-account-sdk-local.py"))
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)
INVENTORY = {
    "Sources/EdithExtensionAccounts": ["ClaudeAccount.swift", "ClaudeAccountStorage.swift", "ClaudeSavedLogin.swift", "OwnedAccountFiles.swift"],
    "Tests/EdithExtensionAccountsTests": ["AccountSupportModelTests.swift", "AccountSupportSavedLoginTests.swift", "AccountSupportStorageTests.swift"],
}


class SyntheticProcess:
    pid = 123

    def __init__(self, polls, waits=None):
        self.polls = iter(polls)
        self.waits = iter(waits or [0])
        self.returncode = None

    def poll(self):
        self.returncode = next(self.polls, self.returncode)
        return self.returncode

    def wait(self, timeout):
        value = next(self.waits, self.returncode)
        if isinstance(value, Exception):
            raise value
        self.returncode = value
        return value


class SyntheticOwnership:
    def __init__(self, active=None, errors=None):
        self.active = active or []
        self.errors = errors or []
        self.signals = []

    def refresh(self):
        return self.active

    def conflicts(self):
        return []

    def terminate(self, value):
        self.signals.append(value)
        self.active = []


class SyntheticClock:
    def __init__(self, values):
        self.values = iter(values)
        self.last = 0

    def __call__(self):
        self.last = next(self.values, self.last)
        return self.last


class AccountSDKLocalGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="account-sdk-helper-contract-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        self.package = self.base / "package"
        self.package.mkdir(mode=0o700)
        self.bytes = {}
        for group, names in INVENTORY.items():
            directory = self.root / "Packages/ExtensionSupport" / group
            directory.mkdir(parents=True, mode=0o700)
            for index, name in enumerate(names):
                data = ("import Foundation\n" + ("@Test func synthetic" + str(index) + "() {}\n" if group.startswith("Tests/") else "struct Synthetic" + str(index) + " {}\n")).encode()
                (directory / name).write_bytes(data)
                self.bytes[group + "/" + name] = data

    def source(self, group):
        return self.root / "Packages/ExtensionSupport" / group

    def test_exact_seven_source_bytes_hashes_and_dependency_free_manifest(self):
        digests, count = HELPER.prepare_package(self.root, self.package)
        files = sorted(path.relative_to(self.package).as_posix() for path in self.package.rglob("*") if path.is_file())
        self.assertEqual(files, sorted(["Package.swift", *self.bytes]))
        self.assertEqual(set(digests), set(self.bytes))
        self.assertEqual(count, 3)
        for name, data in self.bytes.items():
            self.assertEqual((self.package / name).read_bytes(), data)
            self.assertEqual(digests[name], hashlib.sha256(data).hexdigest())
        manifest = (self.package / "Package.swift").read_text()
        self.assertEqual(manifest, HELPER.MANIFEST)
        self.assertEqual(manifest.count(".target("), 1)
        self.assertEqual(manifest.count(".testTarget("), 1)
        self.assertIn('name: "EdithExtensionAccounts"', manifest)
        self.assertIn('dependencies: ["EdithExtensionAccounts"]', manifest)
        self.assertIn(".macOS(.v14)", manifest)
        self.assertEqual(manifest.count(".swiftLanguageMode(.v5)"), 2)
        for forbidden in [".package(", ".executable", "resources:", "plugins:", "EdithExtensionSupport", "EdithExtensionUI", "EdithHost", "Keychain", "SSH"]:
            self.assertNotIn(forbidden, manifest)

    def test_missing_or_extra_swift_source_rejects_in_both_groups(self):
        for group, names in INVENTORY.items():
            for kind in ["missing", "extra"]:
                with self.subTest(group=group, kind=kind):
                    changed = self.source(group) / (names[0] if kind == "missing" else "Unexpected.swift")
                    if kind == "missing":
                        changed.unlink()
                    else:
                        changed.write_text("struct Unexpected {}\n")
                    with self.assertRaises(ValueError):
                        HELPER.prepare_package(self.root, self.package)
                    if kind == "missing":
                        changed.write_bytes(self.bytes[group + "/" + names[0]])
                    else:
                        changed.unlink()

    def test_symlinked_source_file_rejects_without_reading_external_bytes(self):
        for group, names in INVENTORY.items():
            with self.subTest(group=group):
                source = self.source(group) / names[0]
                outside = self.base / "synthetic-external.swift"
                outside.write_bytes(b"synthetic external bytes\n")
                source.unlink()
                source.symlink_to(outside)
                with self.assertRaises(ValueError):
                    HELPER.prepare_package(self.root, self.package)
                self.assertEqual(outside.read_bytes(), b"synthetic external bytes\n")
                source.unlink()
                source.write_bytes(self.bytes[group + "/" + names[0]])

    def test_symlinked_group_rejects(self):
        for group in INVENTORY:
            with self.subTest(group=group):
                source = self.source(group)
                moved = source.with_name(source.name + "-synthetic-moved")
                source.rename(moved)
                source.symlink_to(moved, target_is_directory=True)
                with self.assertRaises(ValueError):
                    HELPER.prepare_package(self.root, self.package)
                source.unlink()
                moved.rename(source)

    def test_symlinked_source_ancestor_rejects(self):
        for parent in ["Sources", "Tests"]:
            with self.subTest(parent=parent):
                source = self.root / "Packages/ExtensionSupport" / parent
                moved = source.with_name(parent + "-synthetic-moved")
                source.rename(moved)
                source.symlink_to(moved, target_is_directory=True)
                with self.assertRaises(ValueError):
                    HELPER.prepare_package(self.root, self.package)
                source.unlink()
                moved.rename(source)

    def test_existing_generated_package_cannot_compile_stale_extra_sources(self):
        for group in INVENTORY:
            with self.subTest(group=group):
                HELPER.prepare_package(self.root, self.package)
                extra = self.package / group / "Unexpected.swift"
                extra.write_text("struct Unexpected {}\n")
                try:
                    try:
                        HELPER.prepare_package(self.root, self.package)
                    except ValueError:
                        pass
                    else:
                        self.assertEqual(sorted(path.name for path in (self.package / group).glob("*.swift")), sorted(INVENTORY[group]))
                finally:
                    if extra.exists():
                        extra.unlink()

    def test_unchanged_package_preserves_mtimes_and_only_changed_source_is_rewritten(self):
        HELPER.prepare_package(self.root, self.package)
        files = [self.package / "Package.swift", *(self.package / name for name in self.bytes)]
        timestamp = 1_650_000_000_000_000_000
        for path in files:
            os.utime(path, ns=(timestamp, timestamp))
        original = {path: path.stat().st_mtime_ns for path in files}
        HELPER.prepare_package(self.root, self.package)
        self.assertEqual({path: path.stat().st_mtime_ns for path in files}, original)
        relative = next(iter(self.bytes))
        source = self.root / "Packages/ExtensionSupport" / relative
        source.write_bytes(self.bytes[relative] + b"\n")
        HELPER.prepare_package(self.root, self.package)
        changed = self.package / relative
        self.assertEqual(changed.read_bytes(), source.read_bytes())
        self.assertNotEqual(changed.stat().st_mtime_ns, original[changed])
        self.assertTrue(all(path.stat().st_mtime_ns == original[path] for path in files if path != changed))

    def test_private_file_rejects_links_public_modes_and_special_files_before_writing(self):
        for kind in ["symlink", "hardlink", "public", "readonly", "directory"]:
            with self.subTest(kind=kind):
                directory = self.base / ("private-file-" + kind)
                directory.mkdir(mode=0o700)
                original = directory / "synthetic-original"
                original.write_bytes(b"synthetic unchanged")
                original.chmod(0o600)
                requested = directory / "destination"
                if kind == "symlink":
                    requested.symlink_to(original)
                elif kind == "hardlink":
                    os.link(original, requested)
                elif kind in ["public", "readonly"]:
                    requested.write_bytes(b"synthetic public")
                    requested.chmod(0o644 if kind == "public" else 0o400)
                else:
                    requested.mkdir(mode=0o700)
                with self.assertRaises((ValueError, OSError)):
                    HELPER.write_private(requested, b"synthetic replacement")
                self.assertEqual(original.read_bytes(), b"synthetic unchanged")
                if kind in ["public", "readonly"]:
                    self.assertEqual(requested.read_bytes(), b"synthetic public")

    def test_private_file_requests_nonblocking_admission_before_fifo_type_check(self):
        requested = self.base / "synthetic-fifo"
        os.mkfifo(requested, mode=0o600)
        actual_open = os.open
        calls = []
        def recording_open(path, flags, mode=0o777):
            calls.append(flags)
            return actual_open(path, flags | os.O_NONBLOCK, mode)
        with patch.object(HELPER.os, "open", side_effect=recording_open):
            with self.assertRaises((ValueError, OSError)):
                HELPER.write_private(requested, b"synthetic replacement")
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0] & os.O_NOFOLLOW)
        self.assertTrue(calls[0] & os.O_NONBLOCK)
        self.assertTrue(stat.S_ISFIFO(requested.lstat().st_mode))

    def test_environment_drops_inherited_runtime_and_authentication_variables(self):
        fixture = self.base / "fixture"
        fixture.mkdir(mode=0o700)
        inherited = {
            "PATH": "/usr/bin:/bin", "LANG": "C", "DEVELOPER_DIR": "/synthetic/toolchain",
            "HOME": "/synthetic/original-home", "TMPDIR": "/synthetic/original-tmp",
            "EDITH_EXTENSION_ID": "other", "EDITH_APPLICATION_IDENTIFIER": "synthetic.original",
            "EDITH_EXTENSION_TEST_SDK": "synthetic-sdk", "EDITH_TEST_VOICE_MODEL": "synthetic-model",
            "EDITH_SHARED_DEFAULTS_SUITE": "synthetic.original", "EDITH_MAKE_GATE": "skip",
            "ANTHROPIC_API_KEY": "synthetic-secret", "ANTHROPIC_AUTH_TOKEN": "synthetic-secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-secret", "CLAUDE_CONFIG_DIR": "/synthetic/original-cli",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/synthetic/original-secret", "SSH_AUTH_SOCK": "/synthetic/socket",
            "AWS_SECRET_ACCESS_KEY": "synthetic-secret", "GITHUB_TOKEN": "synthetic-secret",
        }
        with patch.dict(os.environ, inherited, clear=True):
            environment = HELPER.environment(fixture)
        self.assertEqual(environment["PATH"], inherited["PATH"])
        self.assertEqual(environment["LANG"], "C")
        self.assertEqual(environment["DEVELOPER_DIR"], inherited["DEVELOPER_DIR"])
        self.assertEqual(environment["HOME"], str(fixture))
        self.assertEqual(environment["CFFIXED_USER_HOME"], str(fixture))
        self.assertEqual(environment["EDITH_EXTENSION_ID"], "herdr")
        self.assertEqual(environment["EDITH_APPLICATION_IDENTIFIER"], "com.pulkit.edith.dev.accounts-contracts")
        for key in inherited:
            if key.startswith(("ANTHROPIC_", "CLAUDE_", "AWS_", "SSH_")) or key in ["GITHUB_TOKEN", "EDITH_EXTENSION_TEST_SDK", "EDITH_TEST_VOICE_MODEL", "EDITH_SHARED_DEFAULTS_SUITE", "EDITH_MAKE_GATE"]:
                self.assertNotIn(key, environment)
        for key in ["TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "EDITH_EXTENSION_DATA_ROOT", "EDITH_EXTENSION_STATE_ROOT"]:
            self.assertTrue(Path(environment[key]).is_relative_to(fixture), key)

    def test_fresh_environment_directories_are_private_owned_and_separate(self):
        roots = [self.base / "first", self.base / "second"]
        for fixture in roots:
            fixture.mkdir(mode=0o700)
            HELPER.environment(fixture)
            for relative in ["", "tmp", "cache", "config", "security", "modules", "Data", "Data/herdr", "ExtensionState"]:
                path = fixture / relative
                self.assertFalse(path.is_symlink())
                self.assertEqual(path, path.resolve())
                metadata = path.stat()
                self.assertTrue(stat.S_ISDIR(metadata.st_mode))
                self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o700)
                self.assertEqual(metadata.st_uid, os.getuid())
        (roots[0] / "tmp/synthetic-marker").write_text("synthetic isolated state")
        self.assertFalse((roots[1] / "tmp/synthetic-marker").exists())

    def test_empty_synthetic_test_inventory_cannot_report_a_pass(self):
        for name in INVENTORY["Tests/EdithExtensionAccountsTests"]:
            (self.source("Tests/EdithExtensionAccountsTests") / name).write_text("import Testing\n")
        with self.assertRaises(ValueError):
            HELPER.prepare_package(self.root, self.package)

    def test_result_never_reports_compile_failure_timeout_or_zero_tests_as_executed(self):
        cases = [
            (1, b"error: synthetic compile failure\n", (1, 0, False)),
            (-9, b"Building synthetic fixtures\n", (1, 0, False)),
            (0, b"Test run started.\nTest run with 0 tests passed.\n", (1, 0, False)),
            (0, b"Build complete.\n", (1, 0, False)),
            (1, b"Test syntheticFailure() started.\n", (1, 0, True)),
            (0, b"Test run with 19 tests in 3 suites passed.\n", (1, 19, True)),
            (0, b"Test run with 20 tests in 3 suites passed.\n", (0, 20, True)),
        ]
        for exit_status, output, expected in cases:
            with self.subTest(exit_status=exit_status, output=output):
                self.assertEqual(HELPER.test_result(exit_status, output, 20), expected)

    def test_owned_timeout_uses_maintained_identity_retirement(self):
        process = SyntheticProcess([None], waits=[0])
        owner = SyntheticOwnership(active=[(123, 100, 1, "/synthetic/swift", 123)])
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, self.base / "timeout.log",
            process_factory=lambda *args, **kwargs: process,
            ownership_factory=lambda *args: owner,
            clock=SyntheticClock([0, 360, 361, 362, 363]), sleep=lambda _: None)
        self.assertTrue(result["timedOut"])
        self.assertNotEqual(result["exitCode"], 0)
        self.assertTrue(result["cleanup"]["reaped"])
        self.assertEqual(result["cleanup"]["remainingOwnedProcesses"], 0)
        self.assertTrue(owner.signals)

    def test_oversized_owned_output_is_bounded_and_cannot_pass(self):
        process = SyntheticProcess([0])
        owner = SyntheticOwnership()
        def create(*args, **kwargs):
            kwargs["stdout"].write(b"x" * (HELPER.OUTPUT_BOUND + 1))
            kwargs["stdout"].flush()
            return process
        output = self.base / "oversized.log"
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, output, process_factory=create,
            ownership_factory=lambda *args: owner, clock=lambda: 0, sleep=lambda _: None)
        self.assertTrue(result["logBoundExceeded"])
        self.assertNotEqual(result["exitCode"], 0)
        self.assertEqual(output.stat().st_size, HELPER.OUTPUT_BOUND)
        self.assertEqual(owner.signals, [])

    def test_sticky_owned_identity_failure_cannot_become_success(self):
        owner = SyntheticOwnership(errors=["Synthetic identity rejected"])
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, self.base / "rejected.log",
            process_factory=lambda *args, **kwargs: SyntheticProcess([0]),
            ownership_factory=lambda *args: owner, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertEqual(result["cleanup"]["ownershipErrors"], owner.errors)
        self.assertEqual(owner.signals, [])

    def test_unjoined_owned_process_never_reports_pass(self):
        process = SyntheticProcess([0], waits=[subprocess.TimeoutExpired("synthetic", 5), subprocess.TimeoutExpired("synthetic", 5)])
        owner = SyntheticOwnership()
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, self.base / "unjoined.log",
            process_factory=lambda *args, **kwargs: process,
            ownership_factory=lambda *args: owner, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertFalse(result["cleanup"]["reaped"])

    def test_unadmitted_leader_is_not_signaled_or_reported_as_owned(self):
        def unavailable(*args):
            raise RuntimeError("Synthetic unavailable identity")
        with patch.object(HELPER.os, "killpg", side_effect=AssertionError("Unverified group signal")):
            result = HELPER.run_owned(
                ["/synthetic/swift"], self.root, {}, self.base / "unadmitted.log",
                process_factory=lambda *args, **kwargs: SyntheticProcess([0]),
                ownership_factory=unavailable, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertEqual(result["cleanup"]["unverifiedOwnedProcesses"], 1)

    def test_natural_owned_completion_does_not_signal(self):
        owner = SyntheticOwnership()
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, self.base / "natural.log",
            process_factory=lambda *args, **kwargs: SyntheticProcess([0]),
            ownership_factory=lambda *args: owner, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 0)
        self.assertEqual(owner.signals, [])

    def test_unadmitted_oversized_log_is_bounded_without_unknown_signals(self):
        def unavailable(*args):
            raise RuntimeError("Synthetic unavailable identity")
        def create(*args, **kwargs):
            kwargs["stdout"].write(b"x" * (HELPER.OUTPUT_BOUND + 1))
            kwargs["stdout"].flush()
            return SyntheticProcess([0])
        output = self.base / "unadmitted-oversized.log"
        with patch.object(HELPER.os, "killpg", side_effect=AssertionError("Unverified group signal")):
            result = HELPER.run_owned(
                ["/synthetic/swift"], self.root, {}, output, process_factory=create,
                ownership_factory=unavailable, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertTrue(result["logBoundExceeded"])
        self.assertEqual(output.stat().st_size, HELPER.OUTPUT_BOUND)
        self.assertEqual(result["cleanup"]["unverifiedOwnedProcesses"], 1)

    def test_actual_run_retains_fixture_until_strict_verified_cleanup(self):
        baseline = {"reaped": True, "remainingOwnedProcesses": 0,
                    "unverifiedOwnedProcesses": 0, "ownershipErrors": [],
                    "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}
        cases = [({}, False), ({"unverifiedOwnedProcesses": 1}, True),
                 ({"ownershipErrors": ["Synthetic sticky rejection"]}, True),
                 ({"reaped": False}, True), ({"remainingOwnedProcesses": 1}, True),
                 ({"pendingOwnedChildren": 1}, True), ({"naturalSurvivorCount": 1}, True), ({}, True)]
        class SyntheticOutput(io.StringIO):
            def __init__(self):
                super().__init__()
                self.buffer = io.BytesIO()
        for index, (changed, retained) in enumerate(cases):
            with self.subTest(cleanup=changed):
                root = self.base / ("run-checkout-" + str(index))
                root.mkdir(mode=0o700)
                fixture = None
                def owned(command, checkout, environment, output):
                    nonlocal fixture
                    fixture = output.parent
                    self.assertEqual(command[0], "/synthetic/toolchain/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test")
                    self.assertEqual(command[1], "--package-path")
                    self.assertNotIn("test", command)
                    self.assertNotIn("/usr/sbin/taskpolicy", command)
                    self.assertNotIn("/usr/bin/nice", command)
                    self.assertEqual(command[command.index("--jobs") + 1], "1")
                    data = (b"Test syntheticFailure() started.\nTest run with 3 tests failed.\n"
                            if retained and not changed else b"Test run with 3 tests in 3 suites passed.\n")
                    HELPER.write_private(output, data)
                    return {"exitCode": 1 if retained else 0, "cleanup": {**baseline, **changed}}
                driver = unittest.mock.Mock()
                driver.validate.return_value = Path("/synthetic/toolchain/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test")
                with patch.object(HELPER, "ROOT", root), patch.object(HELPER.sys, "platform", "darwin"), \
                        patch.object(HELPER.sys, "stdout", SyntheticOutput()), \
                        patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": "/synthetic/toolchain"}, clear=True), \
                        patch.object(HELPER, "prepare_package", return_value=({}, 3)), \
                        patch.object(HELPER.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                        patch.object(HELPER, "run_owned", side_effect=owned):
                    self.assertEqual(HELPER.run(), 1 if retained else 0)
                self.assertIsNotNone(fixture)
                self.assertEqual(fixture.exists(), retained)
                self.assertEqual(driver.validate.call_count, 2)

    def test_private_process_metadata_preserves_closed_stage_witness_and_birth_group(self):
        owner = SyntheticOwnership()
        owner.known = {123: (123, 100, 200, "/synthetic/swift", 123)}
        owner.rejected = {124: (124, 100, 300, "/synthetic/compiler", 123)}
        owner.seals = {123: (123, 100, 200, 123), 124: (124, 100, 300, 123)}
        owner.transitions = [{"previous": owner.known[123], "current": (123, 100, 200, "/synthetic/swift-test", 123)}]
        owner.failure_observations = [{
            "kind": "live_identity_unavailable", "knownSeal": True,
            "originalBirthMatches": None, "originalGroupMatches": None,
            "returnedBytes": 0, "expectedBytes": 136, "status": None,
            "pidMatches": None, "birthMatches": None, "groupMatches": None,
            "uidMatches": None, "realUIDMatches": None, "probeFailed": False,
            "recoveryFailureStage": "first_path",
        }]
        owner.captured_snapshot_failures = [{
            "clause": "executable_path_unavailable", "returnedBytes": 136, "expectedBytes": 136,
            "status": 2, "pidMatches": True, "birthMatches": True, "groupMatches": True,
            "uidMatches": True, "realUIDMatches": True, "parentEnumerated": False,
            "parentIdentityKnown": False, "parentMatches": None, "leaderGroupMatches": True,
        }]
        process = SyntheticProcess([0])
        output = self.base / "metadata.log"
        result = HELPER.run_owned(
            ["/synthetic/swift"], self.root, {}, output,
            process_factory=lambda *args, **kwargs: process, ownership_factory=lambda *args: owner,
            clock=lambda: 0, sleep=lambda _: None)
        expected = {
            "leaderPID": 123, "ownerUID": os.getuid(),
            "knownProcesses": [{"pid": 123, "birthSeconds": 100, "birthMicroseconds": 200,
                                "executable": "/synthetic/swift", "group": 123}],
            "rejectedProcesses": [{"pid": 124, "birthSeconds": 100, "birthMicroseconds": 300,
                                    "executable": "/synthetic/compiler", "group": 123}],
            "originalSeals": [{"pid": 123, "birthSeconds": 100, "birthMicroseconds": 200, "group": 123},
                              {"pid": 124, "birthSeconds": 100, "birthMicroseconds": 300, "group": 123}],
            "executableTransitions": [{"previous": list(owner.transitions[0]["previous"]), "current": list(owner.transitions[0]["current"])}],
            "privateFailureIdentities": [],
            "ownershipFailureObservations": owner.failure_observations,
            "capturedSnapshotFailures": owner.captured_snapshot_failures,
        }
        self.assertEqual(result["processMetadata"], expected)
        self.assertEqual(json.loads(output.with_suffix(".process.json").read_bytes()), expected)

    def test_metadata_write_failure_before_admission_waits_without_unknown_signals(self):
        process = SyntheticProcess([0])
        with patch.object(HELPER, "write_private", side_effect=OSError("Synthetic metadata write failure")), \
                patch.object(HELPER.os, "killpg", side_effect=AssertionError("Unverified group signal")):
            result = HELPER.run_owned(
                ["/synthetic/swift"], self.root, {}, self.base / "initial-write-failed.log",
                process_factory=lambda *args, **kwargs: process,
                ownership_factory=lambda *args: self.fail("Failed metadata write reached admission"),
                clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertEqual(result["failure"], "OSError")
        self.assertTrue(result["cleanup"]["reaped"])
        self.assertEqual(result["cleanup"]["unverifiedOwnedProcesses"], 1)

    def test_metadata_write_failure_after_admission_retires_verified_identities(self):
        owner = SyntheticOwnership(active=[(123, 100, 200, "/synthetic/swift", 123)])
        with patch.object(HELPER, "write_private", side_effect=[None, OSError("Synthetic metadata write failure")]):
            result = HELPER.run_owned(
                ["/synthetic/swift"], self.root, {}, self.base / "admitted-write-failed.log",
                process_factory=lambda *args, **kwargs: SyntheticProcess([None], waits=[0]),
                ownership_factory=lambda *args: owner, clock=SyntheticClock([0, 1, 2, 3]),
                sleep=lambda _: None)
        self.assertEqual(result["exitCode"], 1)
        self.assertEqual(result["failure"], "OSError")
        self.assertTrue(result["cleanup"]["reaped"])
        self.assertEqual(result["cleanup"]["remainingOwnedProcesses"], 0)
        self.assertEqual(result["cleanup"]["unverifiedOwnedProcesses"], 0)
        self.assertTrue(owner.signals)

    def test_local_observation_captures_current_and_original_identity_before_parent_mutation(self):
        owner = HELPER.LocalOwnership.__new__(HELPER.LocalOwnership)
        owner.private_failure_identities = []
        previous = (123, 100, 200, "/synthetic/swift-package", 99)
        current = (123, 100, 200, "/synthetic/swift-build", 123)
        owner.known = {123: previous}
        owner.seals = {123: (123, 100, 200, 99)}
        calls = []
        def parent(tracker, pid, kind, value):
            calls.append((tracker, pid, kind, value))
            tracker.known.clear()
            tracker.seals.clear()
        with patch.object(HELPER.OWNERSHIP.BoundedOwnership, "observe_failure", new=parent):
            owner.observe_failure(123, "birth_or_group_changed", current)
        self.assertEqual(calls, [(owner, 123, "birth_or_group_changed", current)])
        self.assertEqual(owner.private_failure_identities, [{
            "pid": 123, "kind": "birth_or_group_changed", "current": list(current),
            "originalKnown": list(previous), "originalSeal": [123, 100, 200, 99],
        }])
        self.assertEqual(owner.known, {})
        self.assertEqual(owner.seals, {})

    def test_local_observation_bound_still_delegates_every_parent_failure(self):
        owner = HELPER.LocalOwnership.__new__(HELPER.LocalOwnership)
        owner.private_failure_identities = []
        owner.known = {}
        owner.seals = {}
        with patch.object(HELPER.OWNERSHIP.BoundedOwnership, "observe_failure") as parent:
            for pid in range(10):
                owner.observe_failure(pid, "live_identity_unavailable")
        self.assertEqual(len(owner.private_failure_identities), 8)
        self.assertEqual(parent.call_count, 10)
        self.assertTrue(all(row["current"] is None and row["originalKnown"] is None and row["originalSeal"] is None for row in owner.private_failure_identities))

    def test_actual_run_rejects_a_selected_target_swapped_after_the_child_joins(self):
        developer = self.base / "Selected.app/Contents/Developer"
        directory = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        directory.mkdir(mode=0o755, parents=True)
        target = directory / "swift-package"
        target.write_bytes(b"synthetic unexecuted package image")
        target.chmod(0o755)
        (directory / "swift-test").symlink_to("swift-package")
        def inspect(path):
            value = path.lstat()
            fields = {name: getattr(value, name) for name in dir(value) if name.startswith("st_")}
            fields["st_uid"] = 0
            return type("RootOwnedMetadata", (), fields)()
        driver = HELPER.DRIVERS.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect)
        fixture = None
        joined = False
        def owned(command, root, environment, output):
            nonlocal fixture, joined
            fixture = output.parent
            HELPER.write_private(output, b"Test run with 3 tests in 3 suites passed.\n")
            joined = True
            target.write_bytes(b"synthetic replaced package image after join")
            return {"exitCode": 0, "cleanup": {"reaped": True, "remainingOwnedProcesses": 0,
                    "unverifiedOwnedProcesses": 0, "ownershipErrors": [], "pendingOwnedChildren": 0,
                    "naturalSurvivorCount": 0}}
        class SyntheticOutput(io.StringIO):
            def __init__(self):
                super().__init__()
                self.buffer = io.BytesIO()
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.object(HELPER.sys, "stdout", SyntheticOutput()), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": str(developer)}, clear=True), \
                patch.object(HELPER.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch.object(HELPER, "run_owned", side_effect=owned):
            self.assertEqual(HELPER.run(), 1)
        self.assertTrue(joined)
        self.assertTrue(fixture.exists())
        receipt = json.loads((self.root / "local/account-contracts/receipt.json").read_text())
        self.assertEqual(receipt["passedTests"], 3)
        self.assertEqual(receipt["exit"], 1)
        self.assertFalse(receipt["ownership"]["selectedDriverValidated"])
        self.assertEqual(receipt["ownership"]["selectedDriverFailure"], "ValueError")



if __name__ == "__main__":
    unittest.main()
