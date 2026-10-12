import importlib.util
import json
import os
import pathlib
import re
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGETS = {
    "ci-extension-accounts": ("Packages/ExtensionSupport", "herdr", "AccountSupport"),
    "ci-extension-herdr-accounts": ("Extensions/herdr", "herdr", "HerdrAccount"),
    "ci-extension-usage-accounts": ("Extensions/usage", "usage", "ClaudeAccountLimits"),
}
SPEC = importlib.util.spec_from_file_location("focused_contracts", ROOT / "scripts/keep-awake-focused-targets.test.py")
FOCUSED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOCUSED)


def recipe(target):
    source = (ROOT / "Makefile").read_text()
    match = re.search(r"^" + re.escape(target) + r":[^\n]*\n((?:\t[^\n]*\n)+)", source, re.M)
    if match is None:
        raise AssertionError("Missing target " + target)
    return match.group(1).splitlines()


class AccountFocusedTargetsTests(unittest.TestCase):
    cleanup_spy = FOCUSED.KeepAwakeFocusedTargetsTests.cleanup_spy

    def test_each_contract_rejects_untrusted_execution_before_compilation(self):
        for target in TARGETS:
            guard = recipe(target)[0].removeprefix("\t@").replace("$$", "$")
            for key, value in [("GITHUB_ACTIONS", "false"), ("RUNNER_ENVIRONMENT", "self-hosted"), ("RUNNER_OS", "Linux")]:
                with self.subTest(target=target, key=key):
                    environment = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}
                    environment[key] = value
                    result = subprocess.run(["/bin/sh", "-c", guard], env=environment, capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)

    def test_selection_is_fixed_and_original_rejection_tests_are_not_skipped(self):
        for target, (package, owner, suite) in TARGETS.items():
            command = recipe(target)[1]
            self.assertIn("--package-path " + package + " --filter '", command)
            self.assertIn(suite, command)
            self.assertIn("--build-system native --no-parallel --jobs 1 -Xswiftc -j1", command)
            self.assertIn('-Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"', command)
            self.assertIn('EDITH_EXTENSION_DATA_ROOT="$$fixture/Data/' + owner + '"', command)
            self.assertIn('EDITH_EXTENSION_STATE_ROOT="$$fixture/ExtensionState"', command)
            self.assertIn("EDITH_APPLICATION_IDENTIFIER=com.pulkit.edith.dev.accounts-contracts", command)
            self.assertNotIn("--skip", command)
            self.assertNotIn("$(FILTER)", command)
            self.assertNotIn("$(SKIP)", command)
            self.assertIn("/usr/bin/time -p swift test", command)

    def test_each_target_reserves_the_existing_swift_resource_budget(self):
        gate = runpy.run_path(str(ROOT / "scripts/make-resource-gate.py"))
        for target in TARGETS:
            self.assertEqual(gate["profile_for"](target)[:2], (2.5, 2560.0))

    def test_private_fixture_creation_and_cleanup_work_for_canonical_and_alias_roots(self):
        for target, (_, owner, _) in TARGETS.items():
            for alias in [False, True]:
                with self.subTest(target=target, alias=alias), tempfile.TemporaryDirectory(prefix="account-contract-shell-") as temporary:
                    root = pathlib.Path(temporary).resolve()
                    self.cleanup_spy(root)
                    storage = root / "storage"
                    storage.mkdir(mode=0o700)
                    supplied = root / "alias" if alias else storage
                    if alias:
                        supplied.symlink_to(storage, target_is_directory=True)
                    setup = recipe(target)[1].removeprefix("\t@").split("env -u ", 1)[0].replace("$$", "$")
                    self.assertNotIn("swift", setup)
                    paths = ["", "tmp", "cache", "config", "Data", "Data/" + owner, "ExtensionState"]
                    probe = "import json,os,pathlib,stat,sys; root=pathlib.Path(sys.argv[1]); paths=json.loads(sys.argv[2]); print(json.dumps([{'path':str(root/p),'canonical':str((root/p).resolve()),'mode':stat.S_IMODE((root/p).lstat().st_mode),'uid':(root/p).lstat().st_uid,'directory':(root/p).is_dir()} for p in paths]))"
                    shell = setup + shlex.quote(sys.executable) + " -B -c " + shlex.quote(probe) + ' "$fixture" ' + shlex.quote(json.dumps(paths))
                    result = subprocess.run(["/bin/sh", "-c", shell], cwd=root, env={"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(supplied) + "/", "PYTHONDONTWRITEBYTECODE": "1"}, capture_output=True, text=True, check=True, timeout=10)
                    entries = json.loads(result.stdout)
                    self.assertEqual(len(entries), len(paths))
                    fixture = pathlib.Path(entries[0]["path"])
                    self.assertEqual(fixture.parent, storage)
                    for entry in entries:
                        self.assertEqual(entry["path"], entry["canonical"])
                        self.assertTrue(entry["directory"])
                        self.assertEqual(entry["mode"], 0o700)
                        self.assertEqual(entry["uid"], os.getuid())
                    self.assertEqual(json.loads((root / "cleanup-spy.json").read_text())["fixture"], str(fixture))
                    self.assertFalse(fixture.exists())
                    self.assertEqual(list(storage.iterdir()), [])

    def test_cleanup_failure_never_replaces_an_original_failure_with_success(self):
        for target in TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory(prefix="account-contract-status-") as temporary:
                root = pathlib.Path(temporary).resolve()
                self.cleanup_spy(root, status=9)
                setup = recipe(target)[1].removeprefix("\t@").split("env -u ", 1)[0].replace("$$", "$")
                result = subprocess.run(["/bin/sh", "-c", setup + "exit 7"], cwd=root, env={"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root), "PYTHONDONTWRITEBYTECODE": "1"}, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 7)


if __name__ == "__main__":
    unittest.main()
