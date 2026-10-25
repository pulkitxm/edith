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
    "Sources/EdithExtensionAccounts": ["ClaudeAccount.swift", "ClaudeAccountStorage.swift", "ClaudeAccountSessions.swift", "ClaudeSavedLogin.swift", "OwnedAccountFiles.swift"],
    "Tests/EdithExtensionAccountsTests": ["AccountSupportCompatibilityTests.swift", "AccountSupportModelTests.swift", "AccountSupportSavedLoginTests.swift", "AccountSupportSessionTests.swift", "AccountSupportStorageTests.swift"],
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

    def test_exact_source_bytes_hashes_and_dependency_free_manifest(self):
        digests, count = HELPER.prepare_package(self.root, self.package)
        files = sorted(path.relative_to(self.package).as_posix() for path in self.package.rglob("*") if path.is_file())
        self.assertEqual(files, sorted(["Package.swift", *self.bytes]))
        self.assertEqual(set(digests), set(self.bytes))
        self.assertEqual(count, 5)
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



    def test_owned_phase_optional_budget_and_cadence_preserve_default_contract(self):
        import inspect
        parameters = inspect.signature(HELPER.run_owned).parameters
        self.assertEqual(parameters["deadline"].default, 360)
        self.assertEqual(parameters["cadence"].default, 0.1)
        process = SyntheticProcess([None, 0], waits=[0])
        owner = SyntheticOwnership()
        sleeps = []
        result = HELPER.run_owned(
            ["/synthetic/swift-build"], self.root, {}, self.base / "build.log",
            process_factory=lambda *args, **kwargs: process,
            ownership_factory=lambda *args: owner,
            clock=SyntheticClock([0, 360, 361, 362, 363]), sleep=sleeps.append,
            deadline=2400, cadence=0.5)
        self.assertFalse(result["timedOut"])
        self.assertEqual(result["exitCode"], 0)
        self.assertEqual(sleeps, [0.5])
        self.assertTrue(HELPER.verified_cleanup(result["cleanup"]))
        process = SyntheticProcess([None], waits=[0])
        owner = SyntheticOwnership(active=[(123, 100, 1, "/synthetic/swift-build", 123)])
        result = HELPER.run_owned(
            ["/synthetic/swift-build"], self.root, {}, self.base / "expired-build.log",
            process_factory=lambda *args, **kwargs: process,
            ownership_factory=lambda *args: owner,
            clock=SyntheticClock([0, 17, 18, 19, 20]), sleep=lambda _: None,
            deadline=17, cadence=0.5)
        self.assertTrue(result["timedOut"])
        self.assertEqual(result["exitCode"], 1)
        self.assertEqual(result["cleanup"]["naturalSurvivorCount"], 1)

    def test_invalid_owned_phase_bounds_reject_before_any_child_launch(self):
        for field, values in [("deadline", [True, 0, -1, 2401, float("inf"), float("nan"), "360"]),
                              ("cadence", [True, 0, -1, 0.6, float("inf"), float("nan"), "0.1"])]:
            for value in values:
                with self.subTest(field=field, value=value):
                    process = unittest.mock.Mock()
                    with self.assertRaises(ValueError):
                        HELPER.run_owned(["synthetic"], self.root, {}, self.base / "invalid.log",
                                         process_factory=process, **{field: value})
                    process.assert_not_called()


class SuppliedOwnershipRecordContracts(unittest.TestCase):
    def fixtures(self):
        spec = importlib.util.spec_from_file_location(
            "local_record_owner_fixtures", Path(__file__).with_name("test-hosted-native-owner-tests.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_supplied_full_partial_and_failed_records_reach_real_parent_without_query(self):
        fixtures = self.fixtures()
        for mode, expected in [(0, False), (4, True), (12, True), ("partial", None), ("failed", None)]:
            with self.subTest(mode=mode):
                kernel = fixtures.Kernel()
                with patch.object(HELPER.OWNERSHIP.watchdog.ctypes, "CDLL", return_value=kernel):
                    owner = HELPER.LocalOwnership(123, 501)
                info = HELPER.OWNERSHIP.watchdog.ProcessInfo()
                size = kernel.proc_pidinfo(123, 3, 1, type("Pointer", (), {"_obj": info})(), 136)
                info.status = 2
                info.flags = mode if type(mode) is int else 4
                record = (size if type(mode) is int else 0 if mode == "partial" else None,
                          info, mode == "failed")
                with patch.object(kernel, "proc_pidinfo", side_effect=AssertionError("Unexpected kernel query")), \
                        patch.object(HELPER.OWNERSHIP.os, "kill", side_effect=AssertionError("Unexpected signal")), \
                        patch.object(HELPER.OWNERSHIP.BoundedOwnership, "observe_failure",
                                     autospec=True, side_effect=HELPER.OWNERSHIP.BoundedOwnership.observe_failure) as parent:
                    owner.observe_failure(123, "live_identity_unavailable", record=record)
                self.assertEqual(parent.call_count, 1)
                self.assertIs(parent.call_args.kwargs["record"], record)
                self.assertEqual(len(owner.failure_observations), 1)
                self.assertIs(owner.failure_observations[0]["processInExit"], expected)
                self.assertEqual(owner.private_failure_identities[0]["originalSeal"], [123, 100, 7, 123])
                self.assertEqual(kernel.signals, [])

    def test_actual_terminal_refusal_through_local_wrapper_preserves_original_sample_and_error(self):
        fixtures = self.fixtures()
        kernel = fixtures.Kernel()
        kernel.processes[234] = (234, 101, 8, "/synthetic/compiler", 123, 123, 501, 501)
        original = kernel.proc_pidinfo
        exiting = False
        def record(pid, flavor, argument, pointer, size):
            result = original(pid, flavor, argument, pointer, size)
            if result:
                pointer._obj.status = 2
                pointer._obj.flags = 4 if exiting and pid == 234 else 0
            return result
        with patch.object(HELPER.OWNERSHIP.watchdog.ctypes, "CDLL", return_value=kernel), \
                patch.object(kernel, "proc_pidinfo", side_effect=record), \
                patch.object(HELPER.OWNERSHIP.os, "kill", side_effect=kernel.kill):
            owner = HELPER.LocalOwnership(123, 501)
            owner.refresh()
            previous = owner.known[234]
            exiting = True
            kernel.processes[234] = (234, 102, 8, "/synthetic/compiler", 123, 123, 501, 501)
            with patch.object(kernel, "proc_pidinfo", side_effect=record) as reads:
                owner.refresh()
        self.assertEqual([call.args[:3] for call in reads.call_args_list if call.args[0] == 234], [(234, 3, 0)])
        self.assertEqual(owner.errors, ["Live owned process identity unavailable"])
        self.assertEqual(owner.private_failure_identities[0]["originalKnown"], list(previous))
        self.assertEqual(owner.private_failure_identities[0]["originalSeal"], [234, 101, 8, 123])
        row = owner.failure_observations[0]
        self.assertIs(row["processInExit"], True)
        self.assertIs(row["knownSeal"], True)
        self.assertIs(row["birthMatches"], False)
        self.assertEqual(row["returnedBytes"], 136)
        self.assertEqual(kernel.signals, [])


class SelectedPackageLauncherBindingTests(unittest.TestCase):
    def fixtures(self, name, filename):
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_real_common_launcher_authenticates_before_spawn_binds_actual_guard_and_closes_after_join(self):
        drivers = self.fixtures("launcher_pair_fixtures", "test-run-host-swift-testing.py")
        owners = self.fixtures("launcher_owner_fixtures", "test-hosted-native-owner-tests.py")
        self.assertIs(HELPER.DRIVERS, HELPER.OWNERSHIP.DRIVERS)
        with drivers.selected_pair_fixture(HELPER.DRIVERS) as (driver, source, destination):
            kernel = owners.Kernel()
            kernel.processes[123] = (123, 100, 7, str(source), 123, 1, 501, 501)
            kernel.processes[234] = (234, 101, 8, str(source), 123, 123, 501, 501)
            original_info = kernel.proc_pidinfo
            process = SyntheticProcess([None, 0])
            original_poll = process.poll
            captured = {}

            def record(pid, flavor, argument, pointer, size):
                result = original_info(pid, flavor, argument, pointer, size)
                pointer._obj.status = 2
                return result

            def poll():
                value = original_poll()
                if value is None:
                    kernel.processes[234] = (234, 101, 8, str(destination), 234, 123, 501, 501)
                else:
                    kernel.processes.clear()
                return value

            process.poll = poll
            arguments = [str(driver.validate()), "--package-path", "/synthetic/package", "--jobs", "1", "--no-parallel"]
            command = HELPER.DRIVERS.SelectedPackageArguments(driver, arguments)

            def create(argv, **kwargs):
                self.assertIs(type(argv), list)
                self.assertEqual(argv, arguments)
                self.assertEqual(len(HELPER.DRIVERS.ADMITTED_PACKAGE_DRIVER_PAIRS), 1)
                self.assertTrue(kwargs["start_new_session"])
                captured["spawned"] = True
                return process

            def ownership(pid, uid, package_driver_pair=None):
                self.assertTrue(HELPER.DRIVERS.admitted_package_driver_pair(package_driver_pair))
                captured["pair"] = package_driver_pair
                captured["descriptors"] = [row[1] for row in package_driver_pair.images]
                return HELPER.LocalOwnership(pid, uid, package_driver_pair=package_driver_pair)

            with patch.object(HELPER.OWNERSHIP.watchdog.ctypes, "CDLL", return_value=kernel), \
                    patch.object(kernel, "proc_pidinfo", side_effect=record), \
                    patch.object(HELPER.OWNERSHIP.os, "kill", side_effect=kernel.kill), \
                    patch.object(HELPER.os, "getuid", return_value=501):
                clock = owners.Clock()
                with tempfile.TemporaryDirectory(prefix="pure-selected-launch-", dir=os.environ["TMPDIR"]) as runtime:
                    result = HELPER.run_owned(command, source.parent, {}, Path(runtime) / "pure-launch.log",
                                              process_factory=create, ownership_factory=ownership,
                                              clock=clock.now, sleep=clock.sleep)
            self.assertTrue(captured["spawned"])
            self.assertEqual(result["exitCode"], 0)
            self.assertIsNone(result["failure"])
            self.assertTrue(HELPER.verified_cleanup(result["cleanup"]))
            self.assertEqual(result["processMetadata"]["executableTransitions"], [
                {"previous": [234, 101, 8, str(source), 123],
                 "current": [234, 101, 8, str(destination), 234]}])
            self.assertEqual(kernel.signals, [])
            self.assertFalse(HELPER.DRIVERS.admitted_package_driver_pair(captured["pair"]))
            for descriptor in captured["descriptors"]:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
            self.assertEqual(command, arguments)

    def test_wrong_driver_namespace_or_changed_invocation_is_refused_before_process_creation(self):
        fixtures = self.fixtures("wrong_namespace_driver_fixtures", "test-run-host-swift-testing.py")
        for namespace, mismatch in [(HELPER.DRIVERS, True), (fixtures.runtime, False)]:
            with self.subTest(namespace=namespace.__name__), fixtures.selected_pair_fixture(namespace) as (driver, source, _):
                argv = [str(driver.validate()) + ("-foreign" if mismatch else ""), "--jobs", "1"]
                command = HELPER.DRIVERS.SelectedPackageArguments(driver, argv)
                with patch.object(HELPER.subprocess, "Popen") as process, self.assertRaises(ValueError):
                    HELPER.run_owned(command, source.parent, {}, source.parent / "rejected-launch.log")
                process.assert_not_called()
                self.assertFalse((source.parent / "rejected-launch.log").exists())


class OwnedProcessSDKLocalTests(unittest.TestCase):
    names = (
        "lateUnknownMemberAfterLeaderExitRetainsAuthorityWithoutSignalling",
        "joinedLeaderCannotReleaseWhileCapturedDescendantStillLives",
        "unreadableBirthAndFailedMembershipScanNeverBecomeAbsence",
        "reusedGroupNeverProvidesSignalAuthority",
        "cancellationAndSecondRetireJoinOneActualCleanupTask",
    )

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="owned-process-sdk-contract-", dir=os.environ["TMPDIR"])
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        self.package = self.base / "package"
        self.package.mkdir(mode=0o700)
        self.bytes = {}
        for group, names in HELPER.OWNED_GROUPS.items():
            destination = self.root / "Packages/ExtensionSupport" / group
            destination.mkdir(parents=True, mode=0o700)
            for name in names:
                data = (HELPER.ROOT / "Packages/ExtensionSupport" / group / name).read_bytes()
                (destination / name).write_bytes(data)
                self.bytes[group + "/" + name] = data

    def positive_output(self):
        return ("\n".join("Test " + name + "() passed after 0.001 seconds." for name in self.names)
                + "\nTest run with 5 tests in 1 suite passed after 0.1 seconds.\n").encode()

    def test_actual_fifty_sources_and_original_five_methods_are_selected_without_other_targets(self):
        unrelated = self.root / "Packages/ExtensionSupport/Tests/EdithExtensionSupportTests/Unrelated.swift"
        unrelated.write_text("@Test func unrelated() {}\n")
        digests, count = HELPER.prepare_package(self.root, self.package, True)
        self.assertEqual(count, 5)
        self.assertEqual(tuple(HELPER.OWNED_METHODS), self.names)
        self.assertEqual(len(digests), 50)
        self.assertEqual(set(digests), set(self.bytes))
        for name, data in self.bytes.items():
            self.assertEqual((self.package / name).read_bytes(), data)
            self.assertEqual(digests[name], hashlib.sha256(data).hexdigest())
        self.assertFalse((self.package / "Tests/EdithExtensionSupportTests/Unrelated.swift").exists())
        manifest = (self.package / "Package.swift").read_text()
        self.assertEqual(manifest.count(".target("), 1)
        self.assertEqual(manifest.count(".testTarget("), 1)
        self.assertEqual(manifest.count(".swiftLanguageMode(.v5)"), 2)
        self.assertIn('dependencies: ["EdithExtensionSupport"]', manifest)
        for excluded in [".package(", "Ghostty", "ZIP", "ArgumentParser", "EdithExtensionUI", "EdithExtensionAccounts"]:
            self.assertNotIn(excluded, manifest)

    def test_owned_inventory_missing_links_method_drift_and_generated_extras_fail_closed(self):
        source = self.root / "Packages/ExtensionSupport/Sources/EdithExtensionSupport"
        test = self.root / "Packages/ExtensionSupport/Tests/EdithExtensionSupportTests/ExtensionOwnedProcessGroupTests.swift"
        original = test.read_bytes()
        for kind in ["extra", "missing", "link", "method", "stale"]:
            with self.subTest(kind=kind):
                changed = source / "Unexpected.swift"
                if kind == "extra":
                    changed.write_text("struct Unexpected {}\n")
                elif kind == "missing":
                    test.unlink()
                elif kind == "link":
                    test.unlink()
                    test.symlink_to(HELPER.ROOT / "Packages/ExtensionSupport/Tests/EdithExtensionSupportTests/ExtensionOwnedProcessGroupTests.swift")
                elif kind == "method":
                    test.write_bytes(original.replace(self.names[0].encode(), b"unexpectedOriginalMethod"))
                else:
                    HELPER.prepare_package(self.root, self.package, True)
                    changed = self.package / "Tests/EdithExtensionSupportTests/Stale.swift"
                    changed.write_text("@Test func stale() {}\n")
                try:
                    with self.assertRaises(ValueError):
                        HELPER.prepare_package(self.root, self.package, True)
                finally:
                    if kind in ["extra", "stale"]:
                        changed.unlink()
                    else:
                        if test.is_symlink():
                            test.unlink()
                        test.write_bytes(original)

    def test_named_result_requires_five_unique_original_positives_one_suite_and_success(self):
        output = self.positive_output()
        self.assertEqual(HELPER.owned_process_result(0, output), (0, 5, True))
        self.assertEqual(HELPER.owned_process_result(7, output), (7, 5, True))
        invalid = [
            b"Test run with 5 tests in 1 suite passed.\n",
            output.replace(self.names[0].encode(), b"unknownMethod"),
            output.replace(self.names[0].encode(), self.names[1].encode()),
            output + ("Test " + self.names[0] + "() passed.\n").encode(),
            output.replace(b"5 tests in 1 suite", b"5 tests in 2 suites"),
            output.replace(b"5 tests in 1 suite", b"0 tests in 1 suite"),
            output + b"Test run with 5 tests in 1 suite passed.\n",
        ]
        for changed in invalid:
            with self.subTest(output=changed):
                self.assertNotEqual(HELPER.owned_process_result(0, changed)[0], 0)

    def test_owned_environment_has_private_roots_without_account_or_ambient_authority(self):
        fixture = self.base / "fixture"
        fixture.mkdir(mode=0o700)
        inherited = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/synthetic/selected",
                     "EDITH_WORKER": "synthetic", "EDITH_EXTENSION_ID": "ambient",
                     "GITHUB_TOKEN": "synthetic", "SSH_AUTH_SOCK": "/synthetic/socket",
                     "NODE_OPTIONS": "--require /synthetic/preload", "DYLD_INSERT_LIBRARIES": "/synthetic/library"}
        with patch.dict(os.environ, inherited, clear=True):
            environment = HELPER.environment(fixture, owned_process_groups=True)
        self.assertFalse(any(key.startswith("EDITH_") for key in environment))
        for key in ["GITHUB_TOKEN", "SSH_AUTH_SOCK", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES"]:
            self.assertNotIn(key, environment)
        self.assertEqual(environment["PATH"], inherited["PATH"])
        self.assertEqual(environment["DEVELOPER_DIR"], inherited["DEVELOPER_DIR"])
        for key in ["HOME", "TMPDIR", "CFFIXED_USER_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"]:
            self.assertTrue(Path(environment[key]).is_relative_to(fixture))

    def test_actual_fixed_mode_uses_separate_cache_direct_alias_and_strict_fixture_retention(self):
        developer = self.base / "Selected.app/Contents/Developer"
        directory = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        directory.mkdir(parents=True, mode=0o755)
        target = directory / "swift-package"
        target.write_bytes(b"synthetic-unexecuted-package-image")
        target.chmod(0o755)
        alias = directory / "swift-test"
        alias.symlink_to(target.name)
        def inspect(path):
            metadata = path.lstat()
            values = {name: getattr(metadata, name) for name in dir(metadata) if name.startswith("st_")}
            values["st_uid"] = 0
            return type("RootOwnedMetadata", (), values)()
        baseline = {"reaped": True, "remainingOwnedProcesses": 0, "unverifiedOwnedProcesses": 0,
                    "ownershipErrors": [], "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}
        class Output(io.StringIO):
            def __init__(self):
                super().__init__()
                self.buffer = io.BytesIO()
        for mode in ["positive", "missing-name", "pending", "driver-changed"]:
            with self.subTest(mode=mode):
                target.write_bytes(b"synthetic-unexecuted-package-image")
                driver = HELPER.DRIVERS.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect)
                fixture = None
                def owned(command, checkout, environment, output):
                    nonlocal fixture
                    fixture = output.parent
                    self.assertEqual(command[0], str(alias))
                    self.assertNotIn("test", command)
                    self.assertEqual(command[command.index("--filter") + 1], "(" + "|".join(self.names) + ")")
                    self.assertEqual(command[command.index("--jobs") + 1], "1")
                    self.assertIn("--no-parallel", command)
                    self.assertIn("-warnings-as-errors", command)
                    self.assertFalse(any(key.startswith("EDITH_") for key in environment))
                    self.assertTrue(fixture.is_relative_to(self.root / "local/owned-process-group-contracts"))
                    data = self.positive_output()
                    if mode == "missing-name":
                        data = data.replace(self.names[0].encode(), b"unexpected")
                    HELPER.write_private(output, data)
                    if mode == "driver-changed":
                        target.write_bytes(b"changed-synthetic-unexecuted-image-after-join")
                    return {"exitCode": 1 if mode == "pending" else 0,
                            "cleanup": {**baseline, "pendingOwnedChildren": 1 if mode == "pending" else 0}}
                with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                        patch.object(HELPER.sys, "stdout", Output()), \
                        patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": str(developer)}, clear=True), \
                        patch.object(HELPER.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                        patch.object(HELPER, "run_owned", side_effect=owned):
                    self.assertEqual(HELPER.run(True), 0 if mode == "positive" else 1)
                self.assertIsNotNone(fixture)
                self.assertEqual(fixture.exists(), mode != "positive")
                receipt = json.loads((self.root / "local/owned-process-group-contracts/receipt.json").read_bytes())
                self.assertFalse(receipt["isolatedAccountSDK"])
                self.assertTrue(receipt["isolatedOwnedProcessGroupsSDK"])
                self.assertEqual(receipt["expectedTests"], 5)
                self.assertEqual(len(receipt["sourceSHA256"]), 50)
                self.assertFalse((self.root / "local/account-contracts").exists())

    def test_real_make_route_invokes_only_the_fixed_sdk_mode(self):
        make = (HELPER.ROOT / "Makefile").read_text()
        recipe = make.split("ci-extension-owned-process-groups-local:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(recipe, "\tpython3 -B scripts/test-account-sdk-local.py --owned-process-groups")
        self.assertNotIn("swift test", recipe)
        self.assertNotIn("GITHUB_ACTIONS", recipe)

    def test_cli_has_only_two_fixed_modes_and_rejects_unexpected_arguments_before_run(self):
        for arguments in [["unknown"], ["--owned-process-groups", "extra"], ["--filter", "other"]]:
            with self.subTest(arguments=arguments), patch.object(HELPER.sys, "argv", ["helper", *arguments]):
                with patch.object(HELPER, "run") as run:
                    with self.assertRaisesRegex(ValueError, "Unexpected local SDK contract mode"):
                        HELPER.main()
                    run.assert_not_called()
        for arguments, expected in [([], ()), (["--owned-process-groups"], (True,))]:
            with self.subTest(arguments=arguments), patch.object(HELPER.sys, "argv", ["helper", *arguments]):
                with patch.object(HELPER, "run", return_value=0) as run:
                    self.assertEqual(HELPER.main(), 0)
                    run.assert_called_once_with(*expected)


class SelectedFrontendPostJoinTests(unittest.TestCase):
    def test_swapped_frontend_after_verified_retirement_fails_without_changing_clean_retirement(self):
        fixture_spec = importlib.util.spec_from_file_location(
            "sdk_join_driver_fixtures", Path(__file__).with_name("test-run-host-swift-testing.py"))
        fixtures = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixtures)
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as temporary:
            root = Path(temporary).resolve()
            with fixtures.selected_pair_fixture(HELPER.DRIVERS) as (driver, _, destination):
                frontend = destination.with_name("swift-frontend")
                pair = HELPER.DRIVERS.SelectedPackageDriverPair(driver)
                cleanup = {"reaped": True, "remainingOwnedProcesses": 0, "unverifiedOwnedProcesses": 0,
                           "pendingOwnedChildren": 0, "naturalSurvivorCount": 0, "ownershipErrors": []}
                process = SyntheticProcess([0])
                owner = SyntheticOwnership()
                def retired(*args):
                    frontend.write_bytes(b"changed synthetic frontend after owned join")
                    return cleanup
                with patch.object(HELPER.DRIVERS, "SelectedPackageDriverPair", return_value=pair), \
                        patch.object(HELPER.OWNERSHIP, "retire", side_effect=retired):
                    result = HELPER.run_owned(
                        HELPER.DRIVERS.SelectedPackageArguments(driver, [str(driver.validate())]),
                        root, {}, root / "tests.log", process_factory=lambda *args, **kwargs: process,
                        ownership_factory=lambda *args, **kwargs: owner)
                self.assertEqual(result["exitCode"], 1)
                self.assertEqual(result["failure"], "RuntimeError")
                self.assertEqual(result["cleanup"], cleanup)
                self.assertEqual(pair.images, [])
                self.assertNotIn(pair, HELPER.DRIVERS.ADMITTED_PACKAGE_DRIVER_PAIRS)


if __name__ == "__main__":
    unittest.main()
