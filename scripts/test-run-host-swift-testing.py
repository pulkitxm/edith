import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "host_swift_testing", Path(__file__).with_name("run-host-swift-testing.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class SwiftDriverAdmissionTests(unittest.TestCase):
    def fixture(self, kind="swift-frontend"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        developer = root / "Xcode.app/Contents/Developer"
        directory = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        directory.mkdir(parents=True)
        alias = directory / "swift"
        target = alias if kind == "regular" else directory / kind
        target.write_bytes(b"synthetic-unexecuted-driver")
        target.chmod(0o700)
        if alias != target:
            alias.symlink_to(kind)
        return developer, directory, alias, target

    def test_regular_driver_and_known_same_bin_aliases_preserve_invocation_path(self):
        for kind in ["regular", "swift-frontend", "swift-driver"]:
            with self.subTest(kind=kind):
                developer, _, alias, target = self.fixture(kind)
                driver = runtime.SelectedSwiftDriver(developer)
                query = Mock(return_value="/synthetic/build/debug\n")
                self.assertEqual(runtime.binary_directory(driver, query), "/synthetic/build/debug")
                query.assert_called_once_with(
                    [str(alias), "build", "--show-bin-path", "--package-path",
                     "Packages/EdithHost", "--build-system", "native"], text=True, timeout=30)
                self.assertEqual(driver.contract[1], target)
                self.assertEqual(driver.validate(), alias)

    def test_foreign_nested_absolute_and_unknown_aliases_are_rejected(self):
        for kind in ["absolute", "outside", "nested", "unknown", "dangling"]:
            with self.subTest(kind=kind):
                developer, directory, alias, target = self.fixture()
                alias.unlink()
                if kind == "absolute":
                    alias.symlink_to(target)
                elif kind == "outside":
                    alias.symlink_to("../swift-frontend")
                elif kind == "nested":
                    alias.symlink_to("./swift-frontend")
                elif kind == "unknown":
                    alias.symlink_to("clang")
                else:
                    target.unlink()
                    alias.symlink_to("swift-frontend")
                with self.assertRaises((ValueError, FileNotFoundError)):
                    runtime.SelectedSwiftDriver(developer)

    def test_alias_chains_nonregular_mutable_and_nonexecutable_targets_are_rejected(self):
        for kind in ["chain", "directory", "writable", "nonexecutable", "hardlink"]:
            with self.subTest(kind=kind):
                developer, directory, _, target = self.fixture()
                if kind == "chain":
                    target.unlink()
                    alternate = directory / "swift-driver"
                    alternate.write_bytes(b"synthetic-unexecuted-driver")
                    alternate.chmod(0o700)
                    target.symlink_to(alternate.name)
                elif kind == "directory":
                    target.unlink()
                    target.mkdir()
                elif kind == "writable":
                    target.chmod(0o777)
                elif kind == "nonexecutable":
                    target.chmod(0o600)
                else:
                    os.link(target, directory / "duplicate")
                with self.assertRaises(ValueError):
                    runtime.SelectedSwiftDriver(developer)

    def test_developer_and_toolchain_aliases_cannot_bypass_canonical_admission(self):
        developer, _, _, _ = self.fixture()
        alias = developer.parent / "DeveloperAlias"
        alias.symlink_to(developer, target_is_directory=True)
        for selected in [alias, Path(str(developer) + "/../Developer"), developer.parent]:
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                runtime.SelectedSwiftDriver(selected)
        toolchain = developer / "Toolchains/XcodeDefault.xctoolchain"
        moved = toolchain.with_name("Other.xctoolchain")
        toolchain.rename(moved)
        toolchain.symlink_to(moved.name, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.SelectedSwiftDriver(developer)

    def test_foreign_alias_or_driver_owner_is_rejected(self):
        developer, _, alias, target = self.fixture()
        actual_lstat = Path.lstat
        for selected in [alias, target]:
            def metadata(path):
                value = actual_lstat(path)
                if path != selected:
                    return value
                fields = {name: getattr(value, name) for name in dir(value) if name.startswith("st_")}
                fields["st_uid"] = os.getuid() + 1000
                return type("ForeignMetadata", (), fields)()
            with self.subTest(selected=selected), patch.object(Path, "lstat", metadata):
                with self.assertRaises(ValueError):
                    runtime.SelectedSwiftDriver(developer)

    def test_alias_swap_or_target_write_after_admission_never_launches_query(self):
        for kind in ["alias", "target"]:
            with self.subTest(kind=kind):
                developer, directory, alias, target = self.fixture()
                driver = runtime.SelectedSwiftDriver(developer)
                if kind == "alias":
                    other = directory / "swift-driver"
                    other.write_bytes(b"synthetic-unexecuted-other")
                    other.chmod(0o700)
                    alias.unlink()
                    alias.symlink_to(other.name)
                else:
                    target.write_bytes(b"changed-synthetic-unexecuted-driver")
                query = Mock()
                with self.assertRaisesRegex(ValueError, "changed after admission"):
                    runtime.binary_directory(driver, query)
                query.assert_not_called()

    def test_ci_contract_target_retains_existing_suite_and_runs_driver_regressions(self):
        root = Path(__file__).resolve().parents[1]
        make = (root / "Makefile").read_text()
        recipe = make.split("ci-host-invocation:\n", 1)[1].split("\n\n", 1)[0].splitlines()
        self.assertEqual(recipe, [
            "\tpython3 -B scripts/test-host-test-invocation.py",
            "\tpython3 -B scripts/test-run-host-swift-testing.py"])
        self.assertIn("ci-scripts: ci-host-invocation\n", make)

    def test_driver_change_during_query_cannot_publish_a_build_directory(self):
        developer, _, _, target = self.fixture()
        driver = runtime.SelectedSwiftDriver(developer)
        def query(arguments, **options):
            target.write_bytes(b"changed-synthetic-unexecuted-driver")
            return "/synthetic/build/debug\n"
        with self.assertRaisesRegex(ValueError, "changed after admission"):
            runtime.binary_directory(driver, query)

    def test_selected_test_alias_authenticates_the_canonical_immutable_package_image(self):
        developer, directory, _, target = self.fixture("swift-package")
        alias = directory / "swift-test"
        target = directory / "swift-package"
        target.write_bytes(b"synthetic executable")
        target.chmod(0o755)
        alias.symlink_to("swift-package")
        def inspect(path):
            value = path.lstat()
            fields = {name: getattr(value, name) for name in dir(value) if name.startswith("st_")}
            fields["st_uid"] = 0
            return type("RootOwnedMetadata", (), fields)()
        self.assertEqual(runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate(), alias)
        self.assertNotEqual(runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate(), target)
        for changed in [directory, alias, target]:
            with self.subTest(unowned=changed.name):
                def unowned(path):
                    return path.lstat() if path == changed else inspect(path)
                with self.assertRaises(ValueError):
                    runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=unowned).validate()
        for changed in [directory, target]:
            with self.subTest(writable=changed.name):
                mode = changed.stat().st_mode & 0o777
                changed.chmod(0o777)
                try:
                    with self.assertRaises(ValueError):
                        runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate()
                finally:
                    changed.chmod(mode)
        for replacement in ["other-package", "../bin/swift-package"]:
            with self.subTest(alias=replacement):
                alias.unlink()
                if replacement == "other-package":
                    (directory / replacement).write_bytes(b"synthetic other image")
                alias.symlink_to(replacement)
                with self.assertRaises(ValueError):
                    runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate()
        alias.unlink()
        alias.symlink_to("swift-package")
        target.chmod(0o644)
        with self.assertRaises(ValueError):
            runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate()
        target.chmod(0o755)
        hardlink = directory / "synthetic-hardlink"
        os.link(target, hardlink)
        with self.assertRaises(ValueError):
            runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect).validate()

        hardlink.unlink()
        driver = runtime.SelectedSwiftDriver(developer, entry="swift-test", inspect=inspect)
        target.write_bytes(b"changed synthetic package image")
        with self.assertRaisesRegex(ValueError, "changed after admission"):
            driver.validate()


class PackageTestInvocationTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        developer = Path(temporary.name).resolve() / "Xcode.app/Contents/Developer"
        directory = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        directory.mkdir(parents=True)
        directory.chmod(0o755)
        target = directory / "swift-package"
        target.write_bytes(b"synthetic-unexecuted-package-image")
        target.chmod(0o755)
        alias = directory / "swift-test"
        alias.symlink_to(target.name)
        original = Path.lstat
        observations = []
        def inspect(path):
            value = original(path)
            observations.append(path)
            fields = {name: getattr(value, name) for name in dir(value) if name.startswith("st_")}
            fields["st_uid"] = 0
            return type("RootOwnedMetadata", (), fields)()
        return developer, alias, target, inspect, observations

    def test_direct_package_alias_preserves_exact_caller_flags_and_nonzero_joined_exit(self):
        developer, alias, target, inspect, observations = self.fixture()
        arguments = ["--package-path", "Extensions/keepAwake", "--build-system", "native",
                     "--no-parallel", "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc",
                     "-plugin-path", "-Xswiftc", str(developer / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")]
        for status in [0, 7, -9]:
            with self.subTest(status=status), patch.object(Path, "lstat", inspect):
                at_join = []
                def joined(arguments, **options):
                    at_join.append(observations.count(target))
                    return type("JoinedResult", (), {"returncode": status})()
                run = Mock(side_effect=joined)
                self.assertEqual(runtime.run_package_tests(developer, arguments, run), status)
                run.assert_called_once_with([str(alias), *arguments], check=False)
                self.assertGreater(observations.count(target), at_join[0])
                self.assertNotIn("test", run.call_args.args[0])

    def test_driver_mutation_during_success_or_failure_cannot_return_joined_status(self):
        for status in [0, 7]:
            with self.subTest(status=status):
                developer, alias, target, inspect, _ = self.fixture()
                def run(arguments, **options):
                    self.assertEqual(arguments, [str(alias), "--skip-build"])
                    self.assertEqual(options, {"check": False})
                    target.write_bytes(b"changed-synthetic-unexecuted-package-image")
                    return type("JoinedResult", (), {"returncode": status})()
                with patch.object(Path, "lstat", inspect):
                    with self.assertRaisesRegex(ValueError, "changed after admission"):
                        runtime.run_package_tests(developer, ["--skip-build"], run)

    def test_failed_subprocess_join_still_revalidates_driver_and_propagates_failure(self):
        developer, _, target, inspect, observations = self.fixture()
        failure = ChildProcessError("synthetic child wait failed")
        with patch.object(Path, "lstat", inspect):
            at_join = []
            def failed_join(arguments, **options):
                at_join.append(observations.count(target))
                raise failure
            run = Mock(side_effect=failed_join)
            with self.assertRaises(ChildProcessError) as outcome:
                runtime.run_package_tests(developer, ["--skip-build"], run)
            self.assertIs(outcome.exception, failure)
            self.assertGreater(observations.count(target), at_join[0])
            run.assert_called_once()

    def test_failed_subprocess_join_does_not_hide_changed_driver(self):
        developer, _, target, inspect, _ = self.fixture()
        def run(arguments, **options):
            target.write_bytes(b"changed-synthetic-unexecuted-package-image")
            raise ChildProcessError("synthetic child wait failed")
        with patch.object(Path, "lstat", inspect):
            with self.assertRaisesRegex(ValueError, "changed after admission") as outcome:
                runtime.run_package_tests(developer, ["--skip-build"], run)
            self.assertIsInstance(outcome.exception.__context__, ChildProcessError)

    def test_missing_flags_and_duplicate_test_command_are_rejected_before_launch(self):
        for arguments in [[], ["test", "--skip-build"]]:
            with self.subTest(arguments=arguments), patch.object(runtime, "SelectedSwiftDriver") as driver:
                run = Mock()
                with self.assertRaisesRegex(ValueError, "Unexpected package test arguments"):
                    runtime.run_package_tests("/synthetic/developer", arguments, run)
                driver.assert_not_called()
                run.assert_not_called()

    def test_cli_package_mode_uses_real_selected_driver_and_preserves_exit(self):
        developer, alias, _, inspect, _ = self.fixture()
        for status in [0, 7]:
            with self.subTest(status=status), patch.object(Path, "lstat", inspect):
                with patch.dict(runtime.os.environ, {"DEVELOPER_DIR": str(developer)}):
                    with patch.object(runtime.sys, "argv", ["runner", "package-test", "--skip-build"]):
                        with patch.object(runtime.subprocess, "run", return_value=type("JoinedResult", (), {"returncode": status})()) as run:
                            with patch.object(runtime.subprocess, "check_output") as lookup:
                                self.assertEqual(runtime.main(), status)
                                run.assert_called_once_with([str(alias), "--skip-build"], check=False)
                                lookup.assert_not_called()

    def test_unknown_cli_modes_cannot_query_or_launch_a_toolchain(self):
        for mode in ["test", "package", "swift-test", "--help", "unknown"]:
            with self.subTest(mode=mode), patch.object(runtime.sys, "argv", ["runner", mode]):
                with patch.object(runtime.subprocess, "check_output") as lookup:
                    with patch.object(runtime.subprocess, "run") as run:
                        with self.assertRaisesRegex(ValueError, "Unexpected host test arguments"):
                            runtime.main()
                        lookup.assert_not_called()
                        run.assert_not_called()

    def test_keep_recipe_retains_private_fixture_guards_and_all_original_test_flags(self):
        root = Path(__file__).resolve().parents[1]
        recipe = (root / "Makefile").read_text().split("ci-extension-keep-awake:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn('test "$$GITHUB_ACTIONS" = true && test "$$RUNNER_ENVIRONMENT" = github-hosted && test "$$RUNNER_OS" = macOS', recipe)
        prefix = "/usr/bin/time -p python3 -B scripts/run-host-swift-testing.py package-test"
        self.assertEqual(recipe.count(prefix), 1)
        self.assertTrue(recipe.endswith(prefix + ' --package-path Extensions/keepAwake --build-system native --no-parallel --jobs 1 -Xswiftc -j1 -Xswiftc -plugin-path -Xswiftc "$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"'))
        for retained in ["umask 077", "cleanup-keep-awake-fixture.py", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "EDITH_TEST_NATIVE_CAPTURE=0", "EDITH_EXTENSION_DATA_ROOT", "EDITH_SHARED_DEFAULTS_SUITE"]:
            self.assertIn(retained, recipe)


if __name__ == "__main__":
    unittest.main()
