import json
import pathlib
import re
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
        original = (ROOT / "Extensions/Package.swift").read_text()
        focused = (ROOT / "Extensions/keepAwake/Package.swift").read_text()
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
        self.assertIn("trap 'rm -rf \"$$fixture\"' EXIT", command)
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "EDITH_EXTENSION_FIXTURE_HOME", "EDITH_EXTENSION_DATA_ROOT"]:
            self.assertIn(key + '=\"$$fixture', command)
        self.assertIn('EDITH_SHARED_DEFAULTS_SUITE="edith.keepAwake.tests.$$(basename "$$fixture")"', command)
        self.assertIn("swift format lint --strict --recursive Extensions/keepAwake", command)
        self.assertIn("swift test --package-path Extensions/keepAwake --build-system native --no-parallel --jobs 1 -Xswiftc -j1", command)
        self.assertEqual(command.count("/usr/bin/time -p"), 2)

    def test_package_retains_original_production_builder_and_only_keep_awake(self):
        self.assertEqual(recipe("package-extension-keep-awake").strip(), "/usr/bin/time -p bun scripts/build-extension-package.mjs keepAwake")

    def test_manifest_routes_keep_awake_to_its_focused_original_suite(self):
        definitions = json.loads((ROOT / "Extensions/manifest.json").read_text())
        keep_awake = next(value for value in definitions if value["id"] == "keepAwake")
        self.assertEqual(keep_awake["testTargets"], ["ci-extension-keep-awake"])

    def test_native_journey_delegates_the_scoped_hosted_acceptance_driver(self):
        self.assertEqual(recipe("ci-extension-keep-awake-native").strip(), "/usr/bin/time -p python3 -B scripts/test-keep-awake-hosted-acceptance.py")


if __name__ == "__main__":
    unittest.main()
