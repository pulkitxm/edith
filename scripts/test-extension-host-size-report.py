import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("host_size_report", Path(__file__).with_name("extension-host-size-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class HostSizeReportTests(unittest.TestCase):
    def test_selected_scenarios_count_the_host_once_and_only_the_selected_packages(self):
        packages = [
            {"id": identifier, "installedBytes": 100, "downloadBytes": 40}
            for identifier in ["calendar", "clipboard", "systemStats", "usage", "unused"]
        ]
        measured = report.measure_scenarios({"installedBytes": 50}, packages)
        self.assertEqual(measured, [{"name": "Daily tools",
            "extensions": ["calendar", "clipboard", "systemStats", "usage"],
            "installedBytes": 450, "extensionDownloadBytes": 160}])
        self.assertEqual(report.measure_scenarios({"installedBytes": 50}, packages[:3]), [])

    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)
        self.app = self.root / "Fixture.app"
        self.executable = self.app / "Contents/MacOS/Edith"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"synthetic host fixture")
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.baseline = {
            "installedBytes": 1000, "zipBytes": 500, "sourceCommit": "baseline-fixture",
            "configuration": "Release", "architecture": "arm64", "signature": "ad-hoc",
            "xcode": "27.0 (fixture)", "sdk": "27.0",
        }

    def package(self, identifier):
        archive = self.packages / f"{identifier}.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr(f"{identifier}/payload", b"fixture")
        metadata = {
            "id": identifier, "version": "1.0.0", "downloadBytes": archive.stat().st_size,
            "installedBytes": 7, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "sourceFingerprint": f"current-{identifier}",
        }
        (self.packages / f"{identifier}.json").write_text(json.dumps(metadata))

    def test_partial_coverage_lists_unmeasured_features_without_shipping_or_test_claims(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}, {"id": "remaining", "title": "Remaining"}]
        result = report.build_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}, {"id": "remaining"}], index)
        self.assertEqual(result["migratedExtensions"], 1)
        self.assertEqual(result["indexedExtensions"], 2)
        self.assertEqual(result["status"], "partial-package-coverage")
        self.assertEqual(result["unmeasuredExtensions"], ["remaining"])
        self.assertNotIn("appWithAllExtensions", result)
        self.assertEqual(result["appWithMigratedExtensions"]["installedBytes"], self.executable.stat().st_size + 7)
        rendered = report.render_markdown(result, index)
        self.assertIn("1 of the 2 indexed features", rendered)
        self.assertIn("Unmeasured features: Remaining.", rendered)
        self.assertIn("| Sample |", rendered)
        self.assertNotIn("| Remaining |", rendered)
        self.assertNotIn("All 1 migrated extensions pass", rendered)
        self.assertNotIn("not ready to merge", rendered)
        self.assertIn("It does not establish merge readiness", rendered)

    def test_complete_39_package_coverage_does_not_infer_publication_or_release_readiness(self):
        index = [{"id": f"sample{number}", "title": f"Sample {number}"} for number in range(39)]
        for entry in index:
            self.package(entry["id"])
        definitions = [{"id": entry["id"], "contractVersion": 1} for entry in index]
        fingerprints = {entry["id"]: f"current-{entry['id']}" for entry in index}
        result = report.build_report(self.baseline, self.app, self.packages, definitions, index, fingerprints)
        self.assertEqual(result["status"], "all-indexed-packages-measured")
        self.assertEqual(result["unmeasuredExtensions"], [])
        self.assertEqual(result["measurement"]["artifactPublication"], "not-verified")
        self.assertTrue(result["measurement"]["sourceFingerprintsVerified"])
        rendered = report.render_markdown(result, index)
        self.assertIn("All 39 indexed features have measured", rendered)
        self.assertIn("All 39 measured packages", rendered)
        self.assertNotIn("remaining feature migrations", rendered)
        self.assertNotIn("remaining Home card data", rendered)
        self.assertIn("neither publishes them nor proves", rendered)
        self.assertIn("not shipping installer sizes", rendered)
        self.assertIn("size calculation does not verify code signatures", rendered)

    def test_build_provenance_uses_recorded_values_and_is_bound_to_the_executable(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        definitions = [{"id": "sample", "contractVersion": 1}]
        host_build = {
            "hostExecutableSHA256": hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            "sourceCommit": "host-fixture", "configuration": "Release", "optimization": "-Osize",
            "architecture": "arm64", "signature": "ad-hoc", "xcode": "27.0 (fixture)", "sdk": "27.0",
        }
        result = report.build_report(self.baseline, self.app, self.packages, definitions, index, host_build=host_build)
        self.assertEqual(result["measurement"]["hostBuild"]["signature"], "ad-hoc")
        self.assertNotIn("signature", result["measurement"])
        rendered = report.render_markdown(result, index)
        self.assertIn("Baseline build: source commit: `baseline-fixture`; configuration: `Release`", rendered)
        self.assertIn("Host build: source commit: `host-fixture`; configuration: `Release`; optimization: `-Osize`", rendered)
        self.assertIn("signing: `ad-hoc`", rendered)
        host_build["hostExecutableSHA256"] = "stale"
        with self.assertRaisesRegex(ValueError, "executable checksum"):
            report.build_report(self.baseline, self.app, self.packages, definitions, index, host_build=host_build)

    def test_missing_host_build_metadata_never_assumes_its_configuration(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = report.build_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        self.assertEqual(result["measurement"]["hostBuild"], {})
        rendered = report.render_markdown(result, index)
        self.assertIn("Host build: Build configuration was not recorded.", rendered)
        self.assertIn("Current package source fingerprints were not checked", rendered)

    def test_component_totals_account_for_every_regular_file_without_counting_aliases(self):
        files = {
            "Contents/Frameworks/Sparkle.framework/Sparkle": b"updater",
            "Contents/Resources/index.json": b"[]",
            "Contents/Info.plist": b"metadata",
            "Contents/Library/LaunchDaemons/carrier.plist": b"carrier",
            "Contents/_CodeSignature/CodeResources": b"signature",
        }
        for relative, data in files.items():
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.executable.parent / "ed").symlink_to(self.executable)
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = report.build_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        components = result["hostComponents"]
        self.assertEqual(components["hostAndCLI"], len(self.executable.read_bytes()))
        self.assertEqual(components["appUpdater"], len(b"updater"))
        self.assertEqual(components["resources"], len(b"[]"))
        self.assertEqual(components["bundleMetadata"], len(b"metadata") + len(b"carrier") + len(b"signature"))
        self.assertEqual(sum(components.values()), result["appWithoutExtensions"]["installedBytes"])
        rendered = report.render_markdown(result, index)
        self.assertIn("| Sparkle app updater | 7 |", rendered)
        self.assertIn(f"| Total empty host | {sum(components.values()):,} |", rendered)

    def test_platform_retirement_and_verification_are_separate_from_worker_exit(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = report.build_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        rendered = report.render_markdown(result, index)
        self.assertIn("meeting-microphone driver has separate retirement rules and can require a macOS restart", rendered)
        self.assertIn("independently installed OBS Virtual Camera provider", rendered)
        self.assertIn("Edith does not install, remove, or deactivate", rendered)
        self.assertNotIn("confirm camera-provider exit after macOS deactivation", rendered)
        self.assertIn("OS-managed deployment copies", rendered)
        self.assertIn("unregistered feature processes are outside", rendered)
        self.assertIn("does not prove that an OS-managed provider", rendered)
        self.assertIn("PR #1010", rendered)
        self.assertEqual(result["surfaceCustomization"]["verification"], "not-measured-by-size-report")

    def test_stale_or_missing_fingerprints_cannot_produce_size_claims(self):
        (self.packages / "sample.json").write_text(json.dumps({"sourceFingerprint": "older-build"}))
        for fingerprints in [{}, {"sample": "current-build"}]:
            with self.assertRaisesRegex(ValueError, "Rebuild sample"):
                report.build_report({}, Path("missing-app"), self.packages,
                    [{"id": "sample", "contractVersion": 1}], [{"id": "sample"}], fingerprints)

    def test_unindexed_or_duplicate_extensions_cannot_inflate_coverage(self):
        definitions = [{"id": "sample", "contractVersion": 1}]
        for index in [[], [{"id": "other"}], [{"id": "sample"}, {"id": "sample"}]]:
            with self.assertRaisesRegex(ValueError, "host index"):
                report.build_report({}, Path("missing"), Path("missing"), definitions, index)
        with self.assertRaisesRegex(ValueError, "host index"):
            report.build_report({}, Path("missing"), Path("missing"), definitions * 2, [{"id": "sample"}])


if __name__ == "__main__":
    unittest.main()
