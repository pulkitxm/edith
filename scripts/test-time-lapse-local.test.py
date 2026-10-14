import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("time_lapse_local", Path(__file__).with_name("test-time-lapse-local.py"))
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class SyntheticDriver:
    def __init__(self):
        self.path = Path("/synthetic/toolchain/swift-test")
        self.validations = 0

    def validate(self):
        self.validations += 1
        return self.path


class TimeLapseLocalRouteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="time-lapse-pure-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        for suite in HELPER.SUITES:
            source = HELPER.ROOT / "Extensions/timeLapse/Tests" / (suite + ".swift")
            destination = self.root / source.relative_to(HELPER.ROOT)
            destination.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            shutil.copyfile(source, destination)
        for prefix in ["Packages/ExtensionSupport", "Extensions/fixtureSupport"]:
            directory = self.root / prefix
            directory.mkdir(parents=True, mode=0o700)
            (directory / "Package.swift").write_text("synthetic package input")
        for name in ["Makefile", "scripts/make-resource-gate.py", "scripts/test-time-lapse-local.py",
                     "scripts/test-time-lapse-local.test.py", "scripts/test-account-sdk-local.py",
                     "scripts/run-host-swift-testing.py", "scripts/hosted-native-owner-tests.py",
                     "scripts/hosted-host-tests/watchdog.py"]:
            path = self.root / name
            path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            path.write_text("synthetic runtime input")
        self.fixture = self.base / "fixture"
        self.fixture.mkdir(mode=0o700)
        self.cleanup = {"reaped": True, "remainingOwnedProcesses": 0,
                        "unverifiedOwnedProcesses": 0, "ownershipErrors": [],
                        "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}

    def output(self):
        lines = []
        for suite, methods in HELPER.SUITES.items():
            for method in methods:
                count = HELPER.PARAMETER_COUNTS.get(method)
                if count:
                    for number in range(count):
                        lines.append("Test case passing 1 argument value → " + str(number)
                                     + " to " + method + "(value:) started.")
                lines.append("Test " + method + "()"
                             + (" with " + str(count) + " test cases" if count else "")
                             + " passed after 0.001 seconds.")
            lines.append("Suite " + suite + " passed after 0.1 seconds.")
        lines.append("Test run with 15 tests in 2 suites passed after 0.1 seconds.")
        return ("\n".join(lines) + "\n").encode()

    def test_inventory_keeps_every_original_and_parameterized_method_without_skips(self):
        inventory = HELPER.source_inventory(self.root)
        self.assertEqual(len(inventory["methods"]), 15)
        for identity in inventory["methods"]:
            self.assertRegex("TimeLapseExtensionTests." + identity + "()", HELPER.FILTER)
        for identity in ["TimeLapseWriterTests/write()", "ExtraTimeLapseTests/read()", "TimeLapseTestsExtra/read()"]:
            self.assertNotRegex(identity, HELPER.FILTER)
        self.assertIn("TimeLapseTests/libraryRejectsLinkedSessionsAndExternalMetadata", inventory["methods"])
        source = self.root / "Extensions/timeLapse/Tests/TimeLapseTests.swift"
        source.write_text(source.read_text().replace("fiveHoursIsTwoMinutesOfPlayback", "replacedOriginal"))
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root)

    def test_symlinked_source_cannot_enter_the_inventory(self):
        path = self.root / "Extensions/timeLapse/Tests/TimeLapseTests.swift"
        outside = self.base / "outside.swift"
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root)

    def test_unadmitted_volume_alias_and_extra_arguments_fail_before_dispatch(self):
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with patch.object(HELPER, "ROOT", alias), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.object(HELPER.sys, "argv", ["helper"]), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base)}), \
                patch.object(HELPER.RUNTIME, "run_owned") as owned:
            with self.assertRaises(ValueError):
                HELPER.run()
            owned.assert_not_called()
        with patch.object(HELPER.sys, "argv", ["helper", "--skip"]), \
                patch.object(HELPER.RUNTIME, "run_owned") as owned:
            with self.assertRaises(ValueError):
                HELPER.run()
            owned.assert_not_called()
        self.assertFalse((self.root / "local").exists())

    def test_selected_arguments_and_actual_resource_gate_keep_the_native_budget(self):
        argv = HELPER.command("/synthetic/swift-test", self.root, self.fixture, "/synthetic/Xcode")
        self.assertEqual(argv[0], "/synthetic/swift-test")
        self.assertEqual(argv[argv.index("--filter") + 1], HELPER.FILTER)
        self.assertEqual(argv[argv.index("--jobs") + 1], "1")
        self.assertEqual(argv[argv.index("--build-system") + 1], "native")
        self.assertEqual(argv[-1], "/synthetic/Xcode/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")
        for forbidden in ["test", "--skip", "--skip-build", "--parallel", "taskpolicy"]:
            self.assertNotIn(forbidden, argv)
        spec = importlib.util.spec_from_file_location("time_lapse_gate", HELPER.ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertEqual(gate.profile_for("ci-extension-time-lapse-local"), gate.PROFILES["swift-test"])
        make = (HELPER.ROOT / "Makefile").read_text()
        self.assertIn("ci-extension-time-lapse:\n\t$(call UTILITY_EXTENSION_NATIVE_TEST,timeLapse)", make)
        self.assertIn("ci-extension-time-lapse-local:\n\tpython3 -B scripts/test-time-lapse-local.py", make)

    def test_closed_environment_keeps_all_storage_private_and_drops_real_capture_and_hosted_hints(self):
        inherited = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": "/synthetic/Xcode",
                     "HOME": "/synthetic/foreign", "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                     "EDITH_TEST_NATIVE_CAPTURE": "1", "EDITH_FUNCTIONAL_FIXTURE": "1",
                     "ANTHROPIC_API_KEY": "synthetic"}
        with patch.dict(os.environ, inherited, clear=True):
            values = HELPER.environment(self.fixture)
        for key in ["GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "EDITH_FUNCTIONAL_FIXTURE", "ANTHROPIC_API_KEY"]:
            self.assertNotIn(key, values)
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                    "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "EDITH_EXTENSION_DATA_ROOT", "EDITH_EXTENSION_STATE_ROOT"]:
            path = Path(values[key])
            self.assertTrue(path.is_relative_to(self.fixture))
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        self.assertEqual(values["EDITH_TEST_NATIVE_CAPTURE"], "0")
        self.assertEqual(values["EDITH_EXTENSION_ID"], "timeLapse")

    def test_named_results_and_actual_expansion_reject_duplicates_missing_cases_and_wrong_suites(self):
        output = self.output()
        self.assertEqual(HELPER.test_result(0, output), (0, 15, 21, True))
        for bad in [b"", output + output,
                    output.replace(b"TimeLapseRemoteUITests passed", b"ForeignTests passed"),
                    output.replace(b"with 6 test cases", b"with 5 test cases"),
                    output.replace(b"Test case passing 1 argument value", b"Unrelated event", 1),
                    output.replace(b"fiveHoursIsTwoMinutesOfPlayback", b"foreignMethod")]:
            self.assertNotEqual(HELPER.test_result(0, bad)[0], 0)
        self.assertEqual(HELPER.test_result(2, output)[0], 2)

    def synthetic_run(self, cleanup=None, native_status=0, after_join=None):
        driver = SyntheticDriver()
        calls = []
        def owned(argv, root, environment, output):
            self.assertIs(type(argv), HELPER.RUNTIME.DRIVERS.SelectedPackageArguments)
            self.assertIs(argv.driver, driver)
            self.assertEqual(root, self.root)
            self.assertEqual(list(argv), HELPER.command(driver.path, root, output.parent, "/synthetic/Xcode"))
            calls.append(argv)
            output.write_bytes(self.output())
            output.chmod(0o600)
            if after_join:
                after_join(driver)
            return {"exitCode": native_status, "cleanup": cleanup or self.cleanup}
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.object(HELPER.sys, "argv", ["helper"]), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": "/synthetic/Xcode"}), \
                patch.object(HELPER.RUNTIME.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch.object(HELPER.RUNTIME, "run_owned", side_effect=owned), patch("builtins.print"):
            status = HELPER.run()
        storage = self.root / "local/time-lapse-contracts"
        return status, driver, calls, list(storage.glob("fixture-*")), json.loads((storage / "receipt.json").read_text())

    def test_actual_run_retains_typed_driver_revalidates_join_and_removes_only_verified_passing_fixture(self):
        status, driver, calls, fixtures, receipt = self.synthetic_run()
        self.assertEqual(status, 0)
        self.assertEqual(driver.validations, 2)
        self.assertEqual(len(calls), 1)
        self.assertEqual(fixtures, [])
        self.assertEqual(receipt["expandedInvocations"], 21)
        self.assertTrue(receipt["expandedInvocationsQualified"])
        self.assertFalse(receipt["applicationExecution"])

    def test_native_failure_and_every_incomplete_cleanup_field_retain_the_fixture(self):
        status, _, _, fixtures, _ = self.synthetic_run(native_status=2)
        self.assertEqual(status, 2)
        self.assertEqual(len(fixtures), 1)
        for key, value in [("reaped", False), ("remainingOwnedProcesses", 1), ("unverifiedOwnedProcesses", 1),
                           ("ownershipErrors", ["synthetic"]), ("pendingOwnedChildren", 1), ("naturalSurvivorCount", 1)]:
            with self.subTest(key=key):
                status, _, _, fixtures, _ = self.synthetic_run(cleanup={**self.cleanup, key: value})
                self.assertEqual(status, 1)
                self.assertGreater(len(fixtures), 0)

    def test_joined_swapped_driver_cannot_qualify_or_delete_its_fixture(self):
        def swap(driver):
            driver.validate = lambda: (_ for _ in ()).throw(ValueError("synthetic swapped alias"))
        status, _, _, fixtures, receipt = self.synthetic_run(after_join=swap)
        self.assertEqual(status, 1)
        self.assertEqual(len(fixtures), 1)
        self.assertFalse(receipt["selectedDriverValidated"])

    def test_postjoin_source_failure_keeps_new_fixture_and_cannot_reuse_old_receipt(self):
        self.synthetic_run()
        def remove(_):
            (self.root / "Extensions/timeLapse/Tests/TimeLapseTests.swift").unlink()
        with self.assertRaises(ValueError):
            self.synthetic_run(after_join=remove)
        storage = self.root / "local/time-lapse-contracts"
        self.assertFalse((storage / "receipt.json").exists())
        self.assertEqual(len(list(storage.glob("fixture-*/tests.log"))), 1)

    def test_foreign_previous_receipt_is_not_followed_or_removed(self):
        outside = self.base / "outside"
        outside.write_bytes(b"synthetic retained content")
        path = self.base / "receipt.json"
        path.symlink_to(outside)
        with self.assertRaises(OSError):
            HELPER.remove_previous_receipt(path)
        self.assertEqual(outside.read_bytes(), b"synthetic retained content")
        path.unlink()
        path.write_bytes(b"synthetic public file")
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            HELPER.remove_previous_receipt(path)
        self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
