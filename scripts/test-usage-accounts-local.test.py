import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("usage_local", Path(__file__).with_name("test-usage-accounts-local.py"))
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class SyntheticDriver:
    def __init__(self, developer, entry):
        assert entry == "swift-test"
        self.path = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        self.validations = 0

    def validate(self):
        self.validations += 1
        return self.path


class UsageAccountLocalRouteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="usage-route-pure-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        tests = self.root / "Extensions/usage/Tests"
        tests.mkdir(parents=True, mode=0o700)
        for index, suite in enumerate(HELPER.SUITES):
            methods = ["synthetic" + str(number) for number in range(HELPER.METHOD_COUNTS[suite])]
            (tests / (suite + ".swift")).write_text(
                "@Suite struct " + suite + " {\n"
                + "\n".join("@Test func " + method + "() {}" for method in methods) + "\n}\n")
        self.fixture = self.base / "fixture"
        self.fixture.mkdir(mode=0o700)
        self.cleanup = {"reaped": True, "remainingOwnedProcesses": 0,
                        "unverifiedOwnedProcesses": 0, "ownershipErrors": [],
                        "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}

    def test_actual_ci_filter_retains_originals_and_new_backend_suites_without_skips(self):
        make = (HELPER.ROOT / "Makefile").read_text()
        section = re.search(
            r"^ci-extension-usage-accounts:\n((?:\t[^\n]*\n)+)", make, re.M).group(1)
        pattern = re.search(r"--filter '([^']+)'", section).group(1)
        originals = ["UsageAccount", "ClaudeAccountLimits", "ClaudeLimitsReaderTests",
                     "LimitsProviderCollectionTests", "UsageLimitsOwnershipTests",
                     "UsageWorkerControllerTests", "UsageBackupTests", "UsageSurfaceTests",
                     "LimitsStatusItemTests"]
        self.assertEqual(pattern.split("|")[:9], originals)
        for suite in HELPER.SUITES:
            self.assertRegex(suite, pattern)
        self.assertNotIn("--skip", section)
        self.assertIn("ci-extension-usage-accounts-local:\n\tpython3 -B scripts/test-usage-accounts-local.py", make)

    def test_real_resource_gate_reserves_existing_swift_test_budget_for_local_route(self):
        spec = importlib.util.spec_from_file_location("usage_resource_gate", HELPER.ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertEqual(gate.profile_for("ci-extension-usage-accounts-local"), gate.PROFILES["swift-test"])
        self.assertEqual(gate.profile_for("ci-extension-usage-accounts-local"), gate.profile_for("ci-extension-usage-accounts"))

    def test_actual_workflow_selects_pure_contract_target_with_explicit_temporary_root(self):
        workflow = (HELPER.ROOT / ".github/workflows/extension-accounts.yml").read_text()
        for path in ["scripts/test-usage-accounts-local.py", "scripts/test-usage-accounts-local.test.py"]:
            self.assertIn("      - " + path, workflow.split("permissions:", 1)[0])
        step = workflow.split("      - name: Verify local Usage route contracts\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: \"matrix.target == 'ci-extension-usage-accounts'\"", step)
        self.assertIn('TMPDIR: "${{ runner.temp }}"', step)
        self.assertIn("run: make ci-extension-usage-account-contracts", step)
        make = (HELPER.ROOT / "Makefile").read_text()
        target = make.split("ci-extension-usage-account-contracts:\n", 1)[1].split("\n.PHONY:", 1)[0]
        self.assertEqual(target.strip().splitlines(), [
            "python3 -B scripts/test-usage-accounts-local.test.py",
            "\tpython3 -B scripts/test-account-sdk-local.test.py",
        ])

    def test_selection_contains_exact_backend_header_and_affected_baseline_suites(self):
        inventory = HELPER.source_inventory(self.root)
        self.assertEqual(len(inventory["methods"]), 47)
        self.assertEqual(len(inventory["sourceSHA256"]), 7)
        for suite in HELPER.SUITES:
            self.assertRegex("UsageExtensionTests." + suite + "/synthetic()", HELPER.FILTER)
        for identity in ["UsageDashboardRenderingTests/render()", "ClaudeLimitsLoginTestsExtra/test()", "ClaudeLimitsReaderTests/read()"]:
            self.assertNotRegex(identity, HELPER.FILTER)
        (self.root / "Extensions/usage/Tests/ClaudeLimitsLoginTests.swift").unlink()
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root)

    def test_selected_alias_arguments_keep_single_job_native_backend_plugins_and_exact_filter(self):
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        argv = HELPER.command(swift, self.root, self.fixture, developer)
        self.assertEqual(argv[0], str(swift))
        self.assertEqual(argv[argv.index("--filter") + 1], HELPER.FILTER)
        self.assertNotIn("--skip", argv)
        self.assertEqual(argv[argv.index("--jobs") + 1], "1")
        self.assertEqual(argv[argv.index("--build-system") + 1], "native")
        self.assertIn("-j1", argv)
        self.assertEqual(argv[-1], developer + "/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")
        for forbidden in ["test", "--skip-build", "taskpolicy", "--parallel"]:
            self.assertNotIn(forbidden, argv)

    def test_closed_fixture_environment_cannot_inherit_hosted_flags_credentials_or_actual_home(self):
        inherited = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                     "HOME": "/synthetic/foreign", "GITHUB_ACTIONS": "synthetic", "RUNNER_ENVIRONMENT": "synthetic",
                     "ANTHROPIC_API_KEY": "synthetic", "EDITH_EXTENSION_STATE_ROOT": "/synthetic/foreign",
                     "XDG_DATA_HOME": "/synthetic/foreign", "XDG_STATE_HOME": "/synthetic/foreign",
                     "XDG_RUNTIME_DIR": "/synthetic/foreign"}
        with patch.dict(os.environ, inherited, clear=True):
            environment = HELPER.environment(self.fixture)
        for forbidden in ["GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "ANTHROPIC_API_KEY"]:
            self.assertNotIn(forbidden, environment)
        self.assertEqual(environment["HOME"], str(self.fixture))
        self.assertEqual(environment["EDITH_TEST_NATIVE_CAPTURE"], "0")
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
                    "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "EDITH_EXTENSION_STATE_ROOT"]:
            self.assertTrue(Path(environment[key]).is_relative_to(self.fixture))

    def test_zero_wrong_suite_duplicate_summary_and_native_failure_never_pass(self):
        good = b"Test run with 47 tests in 7 suites passed after 0.1 seconds.\n"
        self.assertEqual(HELPER.test_result(0, good), (0, 47, True))
        for output in [b"", good.replace(b"47", b"0"), good.replace(b"7", b"6"), good + good]:
            self.assertNotEqual(HELPER.test_result(0, output)[0], 0)
        self.assertEqual(HELPER.test_result(2, good)[0], 2)

    def run_synthetic(self, exit_status=0, cleanup=None, after_join=None, on_dispatch=None):
        driver = SyntheticDriver("/Applications/Xcode.app/Contents/Developer", "swift-test")
        def owned(argv, root, environment, output):
            self.assertEqual(root, self.root)
            if on_dispatch:
                on_dispatch(argv, driver, output.parent)
            output.write_bytes(b"Test run with 47 tests in 7 suites passed after 0.1 seconds.\n")
            output.chmod(0o600)
            if after_join:
                after_join(driver)
            return {"exitCode": exit_status, "cleanup": cleanup or self.cleanup}
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}), \
                patch.object(HELPER.RUNTIME.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch("builtins.print"), \
                patch.object(HELPER.RUNTIME, "run_owned", side_effect=owned):
            status = HELPER.run()
        storage = self.root / "local/usage-account-contracts"
        return status, driver, list(storage.glob("fixture-*")), json.loads((storage / "receipt.json").read_text())

    def test_actual_run_dispatches_exact_typed_selected_package_arguments_with_retained_driver(self):
        calls = []
        def capture(argv, driver, fixture):
            self.assertIs(type(argv), HELPER.RUNTIME.DRIVERS.SelectedPackageArguments)
            self.assertIs(argv.driver, driver)
            self.assertEqual(list(argv), HELPER.command(
                driver.path, self.root, fixture, "/Applications/Xcode.app/Contents/Developer"))
            calls.append(argv)
        status, driver, _, _ = self.run_synthetic(on_dispatch=capture)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(driver.validations, 2)

    def test_actual_run_path_revalidates_after_join_and_removes_only_passing_clean_fixture(self):
        status, driver, fixtures, receipt = self.run_synthetic()
        self.assertEqual(status, 0)
        self.assertEqual(driver.validations, 2)
        self.assertEqual(fixtures, [])
        self.assertEqual(receipt["expectedMethods"], 47)
        self.assertEqual(receipt["expectedSuites"], 7)
        self.assertEqual(receipt["expectedExpandedInvocations"], 52)
        self.assertFalse(receipt["expandedInvocationsQualified"])

    def test_failing_native_clean_retirement_and_swapped_driver_retain_fixtures(self):
        status, _, fixtures, _ = self.run_synthetic(exit_status=2)
        self.assertEqual(status, 2)
        self.assertEqual(len(fixtures), 1)
        def swap(driver):
            driver.validate = lambda: (_ for _ in ()).throw(ValueError("synthetic changed driver"))
        status, _, fixtures, receipt = self.run_synthetic(after_join=swap)
        self.assertEqual(status, 1)
        self.assertEqual(len(fixtures), 2)
        self.assertFalse(receipt["selectedDriverValidated"])

    def test_each_unverified_cleanup_field_fails_and_retains_its_fixture(self):
        for key, value in [("reaped", False), ("remainingOwnedProcesses", 1), ("unverifiedOwnedProcesses", 1),
                           ("ownershipErrors", ["synthetic"]), ("pendingOwnedChildren", 1), ("naturalSurvivorCount", 1)]:
            with self.subTest(key=key):
                cleanup = {**self.cleanup, key: value}
                status, _, fixtures, _ = self.run_synthetic(cleanup=cleanup)
                self.assertEqual(status, 1)
                self.assertGreater(len(fixtures), 0)

    def test_post_join_source_failure_retains_fixture_and_log(self):
        self.run_synthetic()
        def alter_source(_):
            path = self.root / "Extensions/usage/Tests/ClaudeLimitsLoginTests.swift"
            path.unlink()
        with self.assertRaises(ValueError):
            self.run_synthetic(after_join=alter_source)
        fixtures = list((self.root / "local/usage-account-contracts").glob("fixture-*"))
        self.assertEqual(len(fixtures), 1)
        self.assertTrue((fixtures[0] / "tests.log").is_file())
        self.assertFalse((self.root / "local/usage-account-contracts/receipt.json").exists())

    def test_previous_receipt_symlink_or_public_file_cannot_be_removed(self):
        outside = self.base / "outside"
        outside.write_bytes(b"synthetic retained bytes")
        path = self.base / "receipt.json"
        path.symlink_to(outside)
        with self.assertRaises(OSError):
            HELPER.remove_previous_receipt(path)
        self.assertEqual(outside.read_bytes(), b"synthetic retained bytes")
        path.unlink()
        path.write_bytes(b"synthetic public receipt")
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            HELPER.remove_previous_receipt(path)
        self.assertTrue(path.is_file())


class UsageBackupLocalRouteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="usage-backup-route-pure-", dir=os.environ["TMPDIR"])
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        self.tests = self.root / "Extensions/usage/Tests"
        self.tests.mkdir(parents=True, mode=0o700)
        self.backup = self.tests / "UsageBackupTests.swift"
        self.backup.write_text(
            "@Suite struct UsageBackupTests {\n@Test func " + HELPER.BACKUP_METHOD
            + "() {}\n@Test func unrelatedBackupCase() {}\n}\n")
        self.fixture = self.base / "fixture"
        self.fixture.mkdir(mode=0o700)
        self.cleanup = {"reaped": True, "remainingOwnedProcesses": 0,
                        "unverifiedOwnedProcesses": 0, "ownershipErrors": [],
                        "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}

    def output(self):
        return ("◇ Suite UsageBackupTests started.\n◇ Test " + HELPER.BACKUP_METHOD
                + "() started.\n✔ Test " + HELPER.BACKUP_METHOD
                + "() passed after 0.1 seconds.\n✔ Suite UsageBackupTests passed after 0.1 seconds.\n"
                + "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n").encode()

    def test_closed_selector_and_boolean_cannot_accept_arbitrary_filters(self):
        self.assertFalse(HELPER.backup_boundary_requested([]))
        self.assertTrue(HELPER.backup_boundary_requested(["--backup-boundary"]))
        self.assertEqual(HELPER.expected_counts(False), (47, 7, 52))
        self.assertEqual(HELPER.expected_counts(True), (1, 1, 1))
        for arguments in [["--filter", "synthetic"], ["--backup-boundary", "--backup-boundary"], ["--backup-boundary=true"], ["synthetic"]]:
            with self.assertRaises(ValueError):
                HELPER.backup_boundary_requested(arguments)
        for value in [None, 0, 1, "true", []]:
            with self.assertRaises(ValueError):
                HELPER.source_inventory(self.root, value)

    def test_inventory_requires_exact_single_original_method_and_rejects_duplicate_or_missing(self):
        inventory = HELPER.source_inventory(self.root, True)
        self.assertEqual(inventory["methods"], ["UsageBackupTests/" + HELPER.BACKUP_METHOD])
        self.assertEqual(set(inventory["sourceSHA256"]), {"Extensions/usage/Tests/UsageBackupTests.swift"})
        original = self.backup.read_text()
        for contents in [original.replace(HELPER.BACKUP_METHOD, "differentBackupCase"),
                         original.replace("@Test func unrelatedBackupCase() {}", "@Test func " + HELPER.BACKUP_METHOD + "() {}")]:
            self.backup.write_text(contents)
            with self.assertRaises(ValueError):
                HELPER.source_inventory(self.root, True)

    def test_filter_requires_real_module_suite_method_boundary_and_not_source_filename(self):
        identity = "UsageExtensionTests.UsageBackupTests/" + HELPER.BACKUP_METHOD
        for suffix in ["", "()", "()/UsageBackupTests.swift:258"]:
            self.assertRegex(identity + suffix, HELPER.BACKUP_FILTER)
        for value in ["ForeignModule.UsageBackupTests/" + HELPER.BACKUP_METHOD,
                      identity + "Extra()", "UsageExtensionTests.ForeignSuite/" + HELPER.BACKUP_METHOD,
                      "ForeignModule.Case/method()/UsageExtensionTests.UsageBackupTests/" + HELPER.BACKUP_METHOD]:
            self.assertNotRegex(value, HELPER.BACKUP_FILTER)

    def test_backup_arguments_change_only_filter_and_use_existing_make_budget(self):
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        default = HELPER.command(swift, self.root, self.fixture, developer)
        selected = HELPER.command(swift, self.root, self.fixture, developer, True)
        default[default.index("--filter") + 1] = HELPER.BACKUP_FILTER
        self.assertEqual(selected, default)
        make = (HELPER.ROOT / "Makefile").read_text()
        self.assertIn("ci-extension-usage-backup-local:\n\tpython3 -B scripts/test-usage-accounts-local.py --backup-boundary", make)
        spec = importlib.util.spec_from_file_location("usage_backup_resource_gate", HELPER.ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertEqual(gate.profile_for("ci-extension-usage-backup-local"), gate.PROFILES["swift-test"])

    def test_result_requires_one_actual_named_start_pass_and_suite(self):
        good = self.output()
        self.assertEqual(HELPER.test_result(0, good, True), (0, 1, True))
        for bad in [b"Test run with 1 test in 1 suite passed after 0.1 seconds.\n", good + good,
                    good.replace(b"1 test in 1 suite", b"0 tests in 1 suite"),
                    good.replace(b"1 test in 1 suite", b"1 test in 2 suites"),
                    good.replace(HELPER.BACKUP_METHOD.encode(), b"differentMethod"),
                    good.replace(b"UsageBackupTests", b"ForeignSuite")]:
            self.assertNotEqual(HELPER.test_result(0, bad, True)[0], 0)
        self.assertEqual(HELPER.test_result(2, good, True)[0], 2)
        self.assertNotEqual(HELPER.test_result(-15, good, True)[0], 0)

    def run_synthetic(self, cleanup=None):
        driver = SyntheticDriver("/Applications/Xcode.app/Contents/Developer", "swift-test")
        def owned(argv, root, environment, output):
            self.assertIs(type(argv), HELPER.RUNTIME.DRIVERS.SelectedPackageArguments)
            self.assertIs(argv.driver, driver)
            self.assertEqual(list(argv), HELPER.command(driver.path, root, output.parent, "/Applications/Xcode.app/Contents/Developer", True))
            self.assertTrue(Path(environment["TMPDIR"]).is_relative_to(output.parent))
            output.write_bytes(self.output())
            output.chmod(0o600)
            return {"exitCode": 0, "cleanup": cleanup or self.cleanup}
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base), "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}), \
                patch.object(HELPER.RUNTIME.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch("builtins.print"), patch.object(HELPER.RUNTIME, "run_owned", side_effect=owned):
            status = HELPER.run(True)
        storage = self.root / "local/usage-account-contracts"
        return status, driver, storage, json.loads((storage / "receipt.json").read_text())

    def test_actual_route_binds_retained_driver_and_qualifies_only_original_single_case(self):
        status, driver, storage, receipt = self.run_synthetic()
        self.assertEqual(status, 0)
        self.assertEqual(driver.validations, 2)
        self.assertEqual(list(storage.glob("fixture-*")), [])
        self.assertEqual((receipt["expectedMethods"], receipt["expectedSuites"], receipt["expectedExpandedInvocations"]), (1, 1, 1))
        self.assertTrue(receipt["expandedInvocationsQualified"])
        self.assertTrue(receipt["usageTestsExecuted"])

    def test_backup_route_keeps_failed_cleanup_fixture_and_never_qualifies(self):
        status, _, storage, receipt = self.run_synthetic({**self.cleanup, "unverifiedOwnedProcesses": 1})
        self.assertEqual(status, 1)
        self.assertEqual(len(list(storage.glob("fixture-*"))), 1)
        self.assertFalse(receipt["expandedInvocationsQualified"])


if __name__ == "__main__":
    unittest.main()
