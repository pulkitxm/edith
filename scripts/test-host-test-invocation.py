import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "host_runner", Path(__file__).with_name("run-host-swift-testing.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
ROOT = Path(__file__).resolve().parents[1]


class HostTestInvocationTests(unittest.TestCase):
    developer = "/synthetic/Xcode.app/Contents/Developer"
    helper = Path("/synthetic/toolchain/swiftpm-testing-helper")
    executable = Path(
        "/synthetic/build/EdithHostPackageTests.xctest/Contents/MacOS/EdithHostPackageTests")

    def test_exact_helper_runs_every_swift_testing_target_without_filters_or_skips(self):
        inherited = {"HOME": "/synthetic/private-home", "FIXTURE_TOKEN": "synthetic"}
        runtime = {**inherited, "DYLD_LIBRARY_PATH": "/synthetic/selected-libraries"}
        with patch.object(runner.watchdog, "runtime_contract",
                          return_value=(self.helper, self.executable.parents[2],
                                        self.executable, runtime)) as contract:
            arguments, environment = runner.invocation(self.developer, "/synthetic/build", inherited)
        contract.assert_called_once_with(self.developer, "/synthetic/build",
                                         Path("Packages/EdithHost").resolve(), inherited)
        self.assertEqual(arguments[0], str(self.helper))
        self.assertEqual(arguments[1:3], ["--test-bundle-path", str(self.executable)])
        self.assertEqual(arguments[-3:], [str(self.executable), "--testing-library", "swift-testing"])
        self.assertIn("--skip-build", arguments)
        self.assertIn("--no-parallel", arguments)
        self.assertFalse(any(value in arguments for value in ["--filter", "--skip", "--parallel"]))
        self.assertIs(environment, runtime)

    def test_runtime_guard_failure_prevents_execution(self):
        with patch.object(runner.watchdog, "runtime_contract",
                          side_effect=ValueError("Noncanonical diagnostic executable or bundle path")):
            with patch.object(runner.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "Noncanonical"):
                    runner.execute(self.developer, "/synthetic/build", {}, run=run)
                run.assert_not_called()

    def test_wrong_bundle_executable_cannot_reach_execution(self):
        for executable in [Path("relative/EdithHostPackageTests"),
                           Path("/synthetic/OtherTests.xctest/Contents/MacOS/EdithHostPackageTests"),
                           Path("/synthetic/EdithHostPackageTests.xctest/Contents/MacOS/Other")]:
            with self.subTest(executable=str(executable)):
                with patch.object(runner.watchdog, "runtime_contract",
                                  return_value=(self.helper, executable.parent, executable, {})):
                    with patch.object(runner.subprocess, "run") as run:
                        with self.assertRaises(ValueError):
                            runner.execute(self.developer, "/synthetic/build", {}, run=run)
                        run.assert_not_called()

    def test_nonzero_native_result_is_propagated_with_validated_environment(self):
        environment = {"HOME": "/synthetic/private-home", "NO_COLOR": "1"}
        failure = subprocess.CalledProcessError(7, [str(self.helper)])
        with patch.object(runner, "invocation", return_value=([str(self.helper)], environment)):
            with patch.object(runner.subprocess, "run", side_effect=failure) as run:
                with self.assertRaises(subprocess.CalledProcessError) as outcome:
                    runner.execute(self.developer, "/synthetic/build", {}, run=run)
                self.assertIs(outcome.exception, failure)
                run.assert_called_once_with([str(self.helper)], env=environment, check=True)

    def test_success_runs_once_and_does_not_change_current_process_environment(self):
        inherited = {"HOME": "/synthetic/private-home"}
        runtime = {**inherited, "NO_COLOR": "1"}
        with patch.object(runner, "invocation", return_value=([str(self.helper)], runtime)):
            with patch.object(runner.subprocess, "run") as run:
                runner.execute(self.developer, "/synthetic/build", inherited, run=run)
                run.assert_called_once_with([str(self.helper)], env=runtime, check=True)
        self.assertEqual(inherited, {"HOME": "/synthetic/private-home"})

    def test_arguments_are_rejected_before_toolchain_or_process_lookup(self):
        with patch.object(runner.sys, "argv", ["run-host-swift-testing.py", "unexpected"]):
            with patch.object(runner.subprocess, "check_output") as lookup:
                with self.assertRaisesRegex(ValueError, "Unexpected"):
                    runner.main()
                lookup.assert_not_called()

    def test_standalone_contract_target_is_light_without_a_resource_slot(self):
        spec = importlib.util.spec_from_file_location(
            "host_contract_resource_gate", ROOT / "scripts/make-resource-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        self.assertIsNone(gate.profile_for("ci-host-invocation"))
        self.assertIsNone(gate.cost_for(["ci-host-invocation"]))

    def test_make_builds_once_and_retains_every_xctest_before_swift_testing(self):
        make = (ROOT / "Makefile").read_text()
        recipe = make.split("ci-host: ci-host-invocation\n", 1)[1].split("\n\n", 1)[0].splitlines()
        prerequisites = {
            target: next(row for row in make.splitlines()
                         if row.startswith(target + ":")).partition(":")[2].split()
            for target in ["ci-scripts", "ci-scripts-batch"]
        }
        self.assertIn("ci-host-invocation", prerequisites["ci-scripts"])
        self.assertIn("ci-host-abi", prerequisites["ci-scripts"])
        self.assertIn("ci-host-abi", prerequisites["ci-scripts-batch"])
        self.assertIn("ci-host-abi:\n\tbun scripts/extension-host-abi.mjs --check\n", make)
        self.assertIn("ci-host-invocation:\n\tpython3 -B scripts/test-host-test-invocation.py\n", make)
        self.assertEqual(len(recipe), 4)
        self.assertTrue(recipe[0].startswith("\tswift format lint --strict"))
        self.assertTrue(recipe[1].startswith("\tswift build --build-tests "))
        self.assertTrue(recipe[2].startswith("\tswift test --skip-build --disable-swift-testing "))
        for row in recipe[1:3]:
            self.assertIn("--package-path Packages/EdithHost --build-system native", row)
            self.assertIn("--jobs $(EXTENSION_SWIFT_JOBS)", row)
            self.assertIn("$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins", row)
            self.assertNotIn("--filter", row)
            self.assertNotIn("--skip ", row)
        self.assertIn("--no-parallel", recipe[2])
        self.assertEqual(recipe[3], "\tpython3 -B scripts/run-host-swift-testing.py")


if __name__ == "__main__":
    unittest.main()
