import hashlib
import importlib.util
import os
from pathlib import Path
import stat
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


if __name__ == "__main__":
    unittest.main()
