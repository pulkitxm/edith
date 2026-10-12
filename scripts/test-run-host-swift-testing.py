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


if __name__ == "__main__":
    unittest.main()
