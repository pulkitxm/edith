import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("herdr_local", Path(__file__).with_name("test-herdr-accounts-local.py"))
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


class HerdrAccountLocalRouteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="herdr-route-pure-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout"
        self.root.mkdir(mode=0o700)
        tests = self.root / "Extensions/herdr/Tests/UI"
        tests.mkdir(parents=True, mode=0o700)
        for index, suite in enumerate(HELPER.SUITES):
            methods = ["synthetic" + str(number) for number in range(19 if index == 0 else 6)]
            if suite == "HerdrSettingsTests":
                methods += list(HELPER.HOSTED_METHODS)
            (tests / (suite + ".swift")).write_text(
                "@Suite struct " + suite + " {\n"
                + "\n".join("@Test func " + method + "() {}" for method in methods) + "\n}\n")
        self.fixture = self.base / "fixture"
        self.fixture.mkdir(mode=0o700)
        self.cleanup = {"reaped": True, "remainingOwnedProcesses": 0,
                        "unverifiedOwnedProcesses": 0, "ownershipErrors": [],
                        "pendingOwnedChildren": 0, "naturalSurvivorCount": 0}

    def test_actual_ci_filter_retains_originals_and_both_auth_suites_without_local_skips(self):
        make = (HELPER.ROOT / "Makefile").read_text()
        section = make.split("ci-extension-herdr-accounts: ghostty-extension\n", 1)[1].split("\n.PHONY:", 1)[0]
        pattern = re.search(r"--filter '([^']+)'", section).group(1)
        for suite in HELPER.SUITES:
            self.assertRegex(suite, pattern)
        self.assertNotIn("--skip", section)
        self.assertIn("ci-extension-herdr-accounts-local:\n\tpython3 -B scripts/test-herdr-accounts-local.py", make)

    def test_real_resource_gate_reserves_existing_swift_test_budget_for_local_route(self):
        spec = importlib.util.spec_from_file_location("herdr_resource_gate", HELPER.ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertEqual(gate.profile_for("ci-extension-herdr-accounts-local"), gate.PROFILES["swift-test"])
        self.assertEqual(gate.profile_for("ci-extension-herdr-accounts-local"), gate.profile_for("ci-extension-herdr-accounts"))

    def test_actual_workflow_selects_pure_contract_target_with_explicit_temporary_root(self):
        workflow = (HELPER.ROOT / ".github/workflows/extension-accounts.yml").read_text()
        for path in ["scripts/test-herdr-accounts-local.py", "scripts/test-herdr-accounts-local.test.py"]:
            self.assertIn("      - " + path, workflow.split("permissions:", 1)[0])
        step = workflow.split("      - name: Verify local Herdr route contracts\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: \"matrix.target == 'ci-extension-herdr-accounts'\"", step)
        self.assertIn('TMPDIR: "${{ runner.temp }}"', step)
        self.assertIn("run: make ci-extension-herdr-account-contracts", step)
        make = (HELPER.ROOT / "Makefile").read_text()
        target = make.split("ci-extension-herdr-account-contracts:\n", 1)[1].split("\n.PHONY:", 1)[0]
        self.assertEqual(target.strip().splitlines(), [
            "python3 -B scripts/test-herdr-accounts-local.test.py",
            "\tpython3 -B scripts/test-account-sdk-local.test.py",
        ])

    def test_selection_contains_all13_suites_and_only_two_exact_window_method_skips(self):
        inventory = HELPER.source_inventory(self.root)
        self.assertEqual(len(inventory["methods"]), 91)
        self.assertEqual(len(inventory["pendingHostedMethods"]), 2)
        for method in HELPER.HOSTED_METHODS:
            self.assertRegex("HerdrUITests.HerdrSettingsTests/" + method + "()", HELPER.SKIP)
            self.assertRegex("HerdrUITests.HerdrSettingsTests/" + method + "()/HerdrUITests/HerdrSettingsTests.swift:179:16", HELPER.SKIP)
            self.assertNotRegex("HerdrUITests.HerdrSettingsTests/" + method + "Extra()/HerdrUITests/HerdrSettingsTests.swift:179:16", HELPER.SKIP)
            self.assertNotRegex("HerdrUITests.Unrelated/synthetic()/HerdrUITests/HerdrSettingsTests.swift:179:16", HELPER.SKIP)
            for module in ["HerdrExtensionTests", "ForeignTests", "HerdrUITestsExtra"]:
                self.assertNotRegex(module + ".HerdrSettingsTests/" + method + "()/HerdrUITests/HerdrSettingsTests.swift:179:16", HELPER.SKIP)
            for other in ["OtherTests/" + method, "HerdrSettingsTests/" + method + "Extra", "HerdrSettingsTests/unrelated"]:
                self.assertNotRegex(other, HELPER.SKIP)
        (self.root / "Extensions/herdr/Tests/UI/HerdrLimitsLoginTests.swift").unlink()
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root)

    def test_filter_matches_only_the_actual_module_suite_component_not_source_locations(self):
        source = "/HerdrUITests/HerdrSettingsTests.swift:323:1"
        unintended = "HerdrUITests.HerdrAccessibilityFixtureTests/restoresOriginalObjectWithoutReplacingItsIdentity()" + source
        self.assertRegex(unintended, "|".join(HELPER.SUITES))
        self.assertNotRegex(unintended, HELPER.FILTER)
        self.assertEqual({suite for suites in HELPER.MODULE_SUITES.values() for suite in suites}, set(HELPER.SUITES))
        self.assertEqual(HELPER.MODULE_SUITES["HerdrExtensionTests"], ("AgentLaunchArgumentsTests", "HerdrLaunchSettingsTests"))
        manifest = (HELPER.ROOT / "Extensions/herdr/Package.swift").read_text()
        for module, directory in [("HerdrExtensionTests", "Core"), ("HerdrUITests", "UI")]:
            self.assertRegex(manifest, re.compile(r'\.testTarget\(\s*name: "' + module + r'".*?path: "Tests/' + directory + r'"', re.S))
            sources = "\n".join(path.read_text() for path in (HELPER.ROOT / "Extensions/herdr/Tests" / directory).glob("*.swift"))
            for suite in HELPER.MODULE_SUITES[module]:
                self.assertRegex(sources, r"\bstruct\s+" + suite + r"\b")
        for module, suites in HELPER.MODULE_SUITES.items():
            for suite in suites:
                self.assertRegex(module + "." + suite, HELPER.FILTER)
                self.assertRegex(module + "." + suite + "/synthetic()" + source, HELPER.FILTER)
                self.assertRegex(module + "." + suite + "/invalidSavedLaunchInputsRejectBeforePaneCreation(input:)" + source, HELPER.FILTER)
                for other in [name for name in HELPER.MODULE_SUITES if name != module] + ["ForeignTests"]:
                    self.assertNotRegex(other + "." + suite + "/synthetic()" + source, HELPER.FILTER)
                for identity in [module + "." + suite + "Extra/synthetic()" + source,
                                 module + ".Unrelated/synthetic()/HerdrUITests/" + suite + ".swift:1:1"]:
                    self.assertNotRegex(identity, HELPER.FILTER)

    def test_selected_alias_arguments_keep_single_job_native_backend_plugins_and_exact_skips(self):
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        argv = HELPER.command(swift, self.root, self.fixture, developer)
        self.assertEqual(argv[0], str(swift))
        self.assertEqual(argv[argv.index("--filter") + 1], HELPER.FILTER)
        self.assertEqual(argv[argv.index("--skip") + 1], HELPER.SKIP)
        self.assertEqual(argv[argv.index("--jobs") + 1], "1")
        self.assertEqual(argv[argv.index("--build-system") + 1], "native")
        self.assertIn("-j1", argv)
        self.assertEqual(argv[-1], developer + "/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")
        for forbidden in ["test", "--skip-build", "taskpolicy", "--parallel"]:
            self.assertNotIn(forbidden, argv)

    def test_closed_fixture_environment_cannot_inherit_hosted_flags_credentials_or_actual_home(self):
        inherited = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                     "HOME": "/synthetic/foreign", "GITHUB_ACTIONS": "synthetic", "RUNNER_ENVIRONMENT": "synthetic",
                     "ANTHROPIC_API_KEY": "synthetic", "EDITH_EXTENSION_STATE_ROOT": "/synthetic/foreign"}
        with patch.dict(os.environ, inherited, clear=True):
            environment = HELPER.environment(self.fixture)
        for forbidden in ["GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "ANTHROPIC_API_KEY"]:
            self.assertNotIn(forbidden, environment)
        self.assertEqual(environment["HOME"], str(self.fixture))
        self.assertEqual(environment["EDITH_TEST_NATIVE_CAPTURE"], "0")
        for key in ["HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "EDITH_EXTENSION_STATE_ROOT"]:
            self.assertTrue(Path(environment[key]).is_relative_to(self.fixture))

    def test_zero_wrong_suite_duplicate_summary_and_native_failure_never_pass(self):
        good = b"Test run with 91 tests in 13 suites passed after 0.1 seconds.\n"
        self.assertEqual(HELPER.test_result(0, good), (0, 91, True))
        for output in [b"", good.replace(b"91", b"0"), good.replace(b"13", b"12"), good + good]:
            self.assertNotEqual(HELPER.test_result(0, output)[0], 0)
        self.assertEqual(HELPER.test_result(2, good)[0], 2)

    def run_synthetic(self, exit_status=0, cleanup=None, after_join=None, on_dispatch=None):
        driver = SyntheticDriver("/Applications/Xcode.app/Contents/Developer", "swift-test")
        def owned(argv, root, environment, output):
            self.assertEqual(root, self.root)
            if on_dispatch:
                on_dispatch(argv, driver, output.parent)
            output.write_bytes(b"Test run with 91 tests in 13 suites passed after 0.1 seconds.\n")
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
        storage = self.root / "local/herdr-account-contracts"
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
        self.assertEqual(receipt["expectedMethods"], 91)
        self.assertEqual(len(receipt["sourceInventory"]["pendingHostedMethods"]), 2)

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
            path = self.root / "Extensions/herdr/Tests/UI/HerdrLimitsLoginTests.swift"
            path.unlink()
        with self.assertRaises(ValueError):
            self.run_synthetic(after_join=alter_source)
        fixtures = list((self.root / "local/herdr-account-contracts").glob("fixture-*"))
        self.assertEqual(len(fixtures), 1)
        self.assertTrue((fixtures[0] / "tests.log").is_file())
        self.assertFalse((self.root / "local/herdr-account-contracts/receipt.json").exists())

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


    def settings_source(self, method=None):
        path = self.root / "Extensions/herdr/Tests/SettingsAction/HerdrSettingsActionTests.swift"
        path.parent.mkdir(exist_ok=True)
        path.write_text("@MainActor @Suite(.serialized) struct " + HELPER.SETTINGS_SUITE
                        + " {\n@Test func " + (method or HELPER.SETTINGS_METHOD) + "() {}\n}\n")
        return path

    def settings_output(self):
        return ("◇ Suite HerdrSettingsActionTests started.\n◇ Test " + HELPER.SETTINGS_METHOD
                + "() started.\n✔ Test " + HELPER.SETTINGS_METHOD + "() passed after 0.01 seconds.\n"
                + "✔ Suite HerdrSettingsActionTests passed after 0.01 seconds.\n"
                + "✔ Test run with 1 test in 1 suite passed after 0.01 seconds.\n").encode()

    def test_settings_switch_is_closed_and_rejects_arbitrary_filters_and_wrong_types(self):
        self.assertFalse(HELPER.settings_action_requested([]))
        self.assertTrue(HELPER.settings_action_requested(["--settings-action"]))
        for arguments in [["--filter", "synthetic"], ["--settings-action", "extra"],
                          ["--settings-action", "--settings-action"], ["--settings"], ["false"]]:
            with self.assertRaises(ValueError):
                HELPER.settings_action_requested(arguments)
        for value in [0, 1, None, "true", [], {}]:
            with self.assertRaises(ValueError):
                HELPER.expected_counts(value)

    def test_settings_source_selects_only_the_exact_action_and_preserves_default_inventory(self):
        original = HELPER.source_inventory(self.root)
        path = self.settings_source()
        action = HELPER.source_inventory(self.root, True)
        self.assertEqual(action["methods"], [HELPER.SETTINGS_SUITE + "/" + HELPER.SETTINGS_METHOD])
        self.assertEqual(action["pendingHostedMethods"], [])
        self.assertEqual(list(action["sourceSHA256"]), [str(path.relative_to(self.root))])
        self.assertEqual(HELPER.source_inventory(self.root), original)
        self.settings_source("unrelated")
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root, True)
        self.settings_source()
        path.write_text(path.read_text().replace("}\n", "@Test func " + HELPER.SETTINGS_METHOD + "() {}\n}\n"))
        with self.assertRaises(ValueError):
            HELPER.source_inventory(self.root, True)

    def test_settings_filter_matches_actual_identity_and_rejects_filename_nearname_and_foreign_module(self):
        manifest = (HELPER.ROOT / "Extensions/herdr/Package.swift").read_text()
        self.assertRegex(manifest, re.compile(
            r'\.testTarget\(\s*name: "HerdrSettingsActionTests", dependencies: \["HerdrUI"\],\s*'
            r'path: "Tests/SettingsAction"', re.S))
        identity = "HerdrSettingsActionTests.HerdrSettingsActionTests/" + HELPER.SETTINGS_METHOD + "()"
        source = "/HerdrUITests/HerdrSettingsActionTests.swift:8:16"
        self.assertRegex(identity, HELPER.SETTINGS_FILTER)
        self.assertRegex(identity + source, HELPER.SETTINGS_FILTER)
        for other in [identity.replace("HerdrSettingsActionTests", "ForeignTests", 1),
                      identity.replace(HELPER.SETTINGS_METHOD, HELPER.SETTINGS_METHOD + "Extra"),
                      "HerdrUITests.Unrelated/synthetic()" + source]:
            self.assertNotRegex(other, HELPER.SETTINGS_FILTER)
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        original = HELPER.command(swift, self.root, self.fixture, developer)
        actual = HELPER.command(swift, self.root, self.fixture, developer, True)
        self.assertEqual(actual[actual.index("--filter") + 1], HELPER.SETTINGS_FILTER)
        actual[actual.index("--filter") + 1] = HELPER.FILTER
        self.assertEqual(actual, original)

    def test_settings_native_result_requires_one_exact_named_method_and_unique_summary(self):
        good = self.settings_output()
        self.assertEqual(HELPER.test_result(0, good, True), (0, 1, True))
        for output in [b"", good.replace(b"1 test in 1 suite", b"0 tests in 0 suites"),
                       good.replace(b"1 suite", b"2 suites"), good + good,
                       good.replace(HELPER.SETTINGS_METHOD.encode(), b"unrelated"),
                       good.replace(("◇ Test " + HELPER.SETTINGS_METHOD + "() started.\n").encode(), b"")]:
            self.assertNotEqual(HELPER.test_result(0, output, True)[0], 0)
        self.assertEqual(HELPER.test_result(2, good, True)[0], 2)

    def test_settings_make_uses_the_exact_maintained_boolean_route_and_shared_swift_budget(self):
        make = (HELPER.ROOT / "Makefile").read_text()
        target = make.split("ci-extension-herdr-settings-local:\n", 1)[1].split("\n.PHONY:", 1)[0]
        self.assertEqual(target.strip(), "python3 -B scripts/test-herdr-accounts-local.py --settings-action")
        spec = importlib.util.spec_from_file_location("settings_gate", HELPER.ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertEqual(gate.profile_for("ci-extension-herdr-settings-local"), gate.PROFILES["swift-test"])

    def test_actual_settings_run_retains_typed_driver_strict_cleanup_and_private_fixture(self):
        self.settings_source()
        driver = SyntheticDriver("/Applications/Xcode.app/Contents/Developer", "swift-test")
        calls = []
        def owned(argv, root, environment, output):
            self.assertIs(type(argv), HELPER.RUNTIME.DRIVERS.SelectedPackageArguments)
            self.assertIs(argv.driver, driver)
            self.assertEqual(list(argv)[list(argv).index("--filter") + 1], HELPER.SETTINGS_FILTER)
            self.assertEqual(environment["HOME"], str(output.parent))
            output.write_bytes(self.settings_output())
            output.chmod(0o600)
            calls.append((root, environment))
            return {"exitCode": 0, "cleanup": self.cleanup}
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base),
                                       "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}), \
                patch.object(HELPER.RUNTIME.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch.object(HELPER.RUNTIME, "run_owned", side_effect=owned), patch("builtins.print"):
            self.assertEqual(HELPER.run(True), 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(driver.validations, 2)
        storage = self.root / "local/herdr-account-contracts"
        receipt = json.loads((storage / "receipt.json").read_text())
        self.assertEqual((receipt["expectedMethods"], receipt["expectedSuites"],
                          receipt["expectedExpandedInvocations"]), (1, 1, 1))
        self.assertTrue(receipt["selectedDriverValidated"])
        self.assertTrue(receipt["expandedInvocationsQualified"])
        self.assertEqual(receipt["ownership"]["cleanup"], self.cleanup)
        self.assertEqual(list(storage.glob("fixture-*")), [])

    def test_settings_positive_native_output_cannot_bypass_failed_cleanup(self):
        self.settings_source()
        driver = SyntheticDriver("/Applications/Xcode.app/Contents/Developer", "swift-test")
        cleanup = {**self.cleanup, "unverifiedOwnedProcesses": 1}
        def owned(argv, root, environment, output):
            output.write_bytes(self.settings_output())
            output.chmod(0o600)
            return {"exitCode": 0, "cleanup": cleanup}
        with patch.object(HELPER, "ROOT", self.root), patch.object(HELPER.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"EDITH_LOCAL_CI_ROOT": str(self.base),
                                       "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}), \
                patch.object(HELPER.RUNTIME.DRIVERS, "SelectedSwiftDriver", return_value=driver), \
                patch.object(HELPER.RUNTIME, "run_owned", side_effect=owned), patch("builtins.print"):
            self.assertEqual(HELPER.run(True), 1)
        storage = self.root / "local/herdr-account-contracts"
        receipt = json.loads((storage / "receipt.json").read_text())
        self.assertEqual(receipt["passedMethods"], 1)
        self.assertFalse(receipt["expandedInvocationsQualified"])
        self.assertEqual(receipt["ownership"]["cleanup"], cleanup)
        self.assertEqual(len(list(storage.glob("fixture-*"))), 1)


if __name__ == "__main__":
    unittest.main()
