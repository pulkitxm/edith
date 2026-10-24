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


def recipe(name):
    source = (ROOT / "Makefile").read_text()
    match = re.search(r"^" + re.escape(name) + r":\n((?:\t[^\n]*\n)+)", source, re.M)
    if match is None:
        raise AssertionError("Missing target " + name)
    return match.group(1)


def swift_target(source, name):
    match = re.search(r'\.(?:testTarget|target)\(\s*name: "' + re.escape(name) + '"', source)
    if match is None:
        raise AssertionError("Missing Swift target " + name)
    start = match.start()
    depth = 0
    for end in range(source.index("(", start), len(source)):
        depth += (source[end] == "(") - (source[end] == ")")
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError("Unbalanced target " + name)


class KeepAwakeFocusedTargetsTests(unittest.TestCase):
    def test_dedicated_package_retains_both_original_targets(self):
        original = '''
        .target(
            name: "KeepAwakeExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "keepAwake", exclude: ["Tests"]),
        .testTarget(
            name: "KeepAwakeExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "KeepAwakeExtension",
            ],
            path: "keepAwake/Tests"),
        '''
        focused = (ROOT / "Extensions/keepAwake/Package.swift").read_text()
        umbrella = (ROOT / "Extensions/Package.swift").read_text()
        self.assertNotIn('name: "KeepAwakeExtension"', umbrella)
        self.assertNotIn('name: "KeepAwakeExtensionTests"', umbrella)
        self.assertIn("platforms: [.macOS(.v14)]", focused)
        self.assertIn('.package(path: "../../Packages/ExtensionSupport")', focused)
        self.assertIn('.package(path: "../fixtureSupport")', focused)
        for name in ["KeepAwakeExtension", "KeepAwakeExtensionTests"]:
            before = swift_target(original, name)
            after = swift_target(focused, name)
            before = before.replace('path: "keepAwake/Tests"', 'path: "Tests"')
            before = before.replace('path: "keepAwake"', 'path: "."')
            self.assertEqual(re.sub(r"\s+", "", before), re.sub(r"\s+", "", after))
        self.assertEqual(focused.count(".testTarget("), 1)
        self.assertEqual(focused.count(".target("), 1)

    def test_original_test_files_remain_in_the_unfiltered_test_directory(self):
        originals = {
            "SurfaceTests.swift", "KeepAwakeFixtureStoreTests.swift", "KeepAwakeStoreTests.swift",
            "ControlPresentationTests.swift", "KeepAwakeRuntimeFixtureTests.swift",
            "ControlSettingsRenderTests.swift",
        }
        present = {path.name for path in (ROOT / "Extensions/keepAwake/Tests").glob("*.swift")}
        self.assertTrue(originals <= present)
        command = recipe("ci-extension-keep-awake")
        self.assertNotIn("--filter", command)
        self.assertNotIn("--skip", command)
        self.assertNotIn("$(FILTER)", command)
        self.assertNotIn("$(SKIP)", command)

    def test_focused_compile_has_no_native_execution_and_one_job(self):
        command = recipe("ci-extension-keep-awake-compile")
        self.assertIn("swift build --package-path Extensions/keepAwake --target KeepAwakeExtensionTests", command)
        self.assertIn("--build-system native --jobs 1 -Xswiftc -j1", command)
        self.assertIn("/usr/bin/time -p", command)
        self.assertNotIn("swift test", command)

    def test_original_native_tests_require_hosted_mac_and_fresh_storage(self):
        command = recipe("ci-extension-keep-awake")
        self.assertTrue(command.startswith('\t@test "$$GITHUB_ACTIONS" = true'))
        self.assertIn('test "$$RUNNER_ENVIRONMENT" = github-hosted', command)
        self.assertIn('test "$$RUNNER_OS" = macOS', command)
        self.assertIn('mktemp -d "$${TMPDIR:-/tmp}/edith-keep-awake-tests.XXXXXX"', command)
        self.assertIn("trap 'status=$$?; if python3 -B scripts/cleanup-keep-awake-fixture.py \"$$fixture\" && rm -rf \"$$fixture\"", command)
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "EDITH_EXTENSION_FIXTURE_HOME", "EDITH_EXTENSION_DATA_ROOT"]:
            self.assertIn(key + '=\"$$fixture', command)
        self.assertIn('EDITH_SHARED_DEFAULTS_SUITE="edith.keepAwake.tests.$$(basename "$$fixture")"', command)
        self.assertIn("swift format lint --strict --recursive Extensions/keepAwake", command)
        self.assertIn("python3 -B scripts/run-host-swift-testing.py package-test --package-path Extensions/keepAwake --build-system native --no-parallel --jobs 1 -Xswiftc -j1", command)
        self.assertEqual(command.count("/usr/bin/time -p"), 2)

    def cleanup_spy(self, root, status=0):
        scripts = root / "scripts"
        scripts.mkdir()
        spy = scripts / "cleanup-keep-awake-fixture.py"
        spy.write_text("""import json, os, pathlib, stat, sys
assert len(sys.argv) == 2
path = pathlib.Path(sys.argv[1])
info = path.lstat()
assert str(path.resolve()) == sys.argv[1]
assert path.name.startswith('edith-keep-awake-tests.')
assert stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
assert info.st_uid == os.getuid()
pathlib.Path('cleanup-spy.json').write_text(json.dumps({'fixture': sys.argv[1]}))
sys.exit(""" + str(status) + ")\n")

    def check_fixture_paths(self, trailing, alias, target="ci-extension-keep-awake"):
        with tempfile.TemporaryDirectory(prefix="keep-awake-shell-") as temporary:
            root = pathlib.Path(temporary).resolve()
            self.cleanup_spy(root)
            storage = root / "storage"
            storage.mkdir(mode=0o700)
            supplied = storage
            if alias:
                supplied = root / "alias"
                supplied.symlink_to(storage, target_is_directory=True)
            command = next(line for line in recipe(target).splitlines() if "mktemp -d" in line)
            setup = command.removeprefix("\t@").split("env -u ", 1)[0].replace("$$", "$")
            self.assertNotIn("swift", setup)
            self.assertNotIn("make ", setup)
            probe = """import json, os, pathlib, stat, sys
paths = [sys.argv[1]] + [sys.argv[1] + '/' + name for name in ['tmp', 'cache', 'config', 'data']]
print(json.dumps([{'path': raw, 'canonical': str(path.resolve()),
                  'directory': stat.S_ISDIR(path.lstat().st_mode),
                  'mode': stat.S_IMODE(path.lstat().st_mode),
                  'uid': path.lstat().st_uid} for raw in paths for path in [pathlib.Path(raw)]]))
"""
            shell = setup + shlex.quote(sys.executable) + " -B -c " + shlex.quote(probe) + ' "$fixture"'
            result = subprocess.run(["/bin/sh", "-c", shell], check=True, text=True,
                                    capture_output=True, timeout=10, cwd=root,
                                    env={"PATH": "/usr/bin:/bin", "HOME": str(root),
                                         "TMPDIR": str(supplied) + ("/" if trailing else ""),
                                         "PYTHONDONTWRITEBYTECODE": "1"})
            entries = json.loads(result.stdout)
            self.assertEqual(len(entries), 5)
            fixture = pathlib.Path(entries[0]["path"])
            self.assertEqual(fixture.parent, storage)
            for entry in entries:
                self.assertEqual(entry["path"], entry["canonical"])
                self.assertTrue(entry["directory"])
                self.assertEqual(entry["mode"], 0o700)
                self.assertEqual(entry["uid"], os.getuid())
                self.assertTrue(pathlib.Path(entry["path"]).is_relative_to(storage))
            self.assertEqual(json.loads((root / "cleanup-spy.json").read_text())["fixture"], str(fixture))
            self.assertFalse(fixture.exists())
            self.assertEqual(list(storage.iterdir()), [])

    def test_native_fixture_canonicalizes_trailing_and_nontrailing_tmpdir(self):
        for trailing in [False, True]:
            with self.subTest(trailing=trailing):
                self.check_fixture_paths(trailing, False)

    def test_native_fixture_canonicalizes_physical_parent_alias(self):
        for trailing in [False, True]:
            with self.subTest(trailing=trailing):
                self.check_fixture_paths(trailing, True)

    def test_exit_trap_preserves_test_failure_and_rejects_cleanup_failure(self):
        for original, cleanup, expected in [(0, 0, 0), (0, 23, 23), (17, 0, 17), (17, 23, 17)]:
            with self.subTest(original=original, cleanup=cleanup):
                with tempfile.TemporaryDirectory(prefix="keep-awake-trap-") as temporary:
                    root = pathlib.Path(temporary).resolve()
                    self.cleanup_spy(root, cleanup)
                    storage = root / "storage"
                    storage.mkdir(mode=0o700)
                    command = recipe("ci-extension-keep-awake").splitlines()[2]
                    setup = command.removeprefix("\t@").split("env -u ", 1)[0].replace("$$", "$")
                    self.assertNotIn("swift", setup)
                    self.assertNotIn("make ", setup)
                    shell = setup + "exit " + str(original)
                    syntax = subprocess.run(["/bin/sh", "-n", "-c", shell], capture_output=True, timeout=10)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
                    result = subprocess.run(["/bin/sh", "-c", shell], capture_output=True, timeout=10,
                                            cwd=root, env={"PATH": "/usr/bin:/bin", "HOME": str(root),
                                                          "TMPDIR": str(storage) + "/",
                                                          "PYTHONDONTWRITEBYTECODE": "1"})
                    self.assertEqual(result.returncode, expected, result.stderr)
                    record = json.loads((root / "cleanup-spy.json").read_text())
                    fixture = pathlib.Path(record["fixture"])
                    self.assertEqual(fixture.parent, storage)
                    self.assertEqual(fixture.exists(), cleanup != 0)
                    if cleanup != 0:
                        self.assertTrue((fixture / "tmp").is_dir())

    def test_package_retains_original_production_builder_and_only_keep_awake(self):
        self.assertEqual(recipe("package-extension-keep-awake").strip(), "/usr/bin/time -p bun scripts/build-extension-package.mjs keepAwake")

    def test_manifest_routes_keep_awake_to_its_focused_original_suite(self):
        definitions = json.loads((ROOT / "Extensions/manifest.json").read_text())
        keep_awake = next(value for value in definitions if value["id"] == "keepAwake")
        self.assertEqual(keep_awake["testTargets"], ["ci-extension-keep-awake"])


if __name__ == "__main__":
    unittest.main()
