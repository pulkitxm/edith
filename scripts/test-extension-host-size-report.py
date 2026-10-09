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
    def test_partial_migration_never_claims_final_shipping_sizes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Fixture.app"
            executable = app / "Contents/MacOS/Edith"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"synthetic host fixture")
            packages = root / "packages"
            packages.mkdir()
            archive = packages / "sample.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("sample/payload", b"fixture")
            metadata = {
                "id": "sample", "version": "1.0.0", "downloadBytes": archive.stat().st_size,
                "installedBytes": 7, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            }
            (packages / "sample.json").write_text(json.dumps(metadata))
            index = [{"id": "sample", "title": "Sample"}, {"id": "remaining", "title": "Remaining"}]
            result = report.build_report(
                {"installedBytes": 1000, "zipBytes": 500, "sourceCommit": "baseline-fixture"},
                app, packages, [{"id": "sample", "contractVersion": 1}, {"id": "remaining"}], index)
            self.assertEqual(result["migratedExtensions"], 1)
            self.assertEqual(result["indexedExtensions"], 2)
            self.assertEqual(result["status"], "migration-in-progress")
            self.assertNotIn("appWithAllExtensions", result)
            self.assertEqual(result["appWithMigratedExtensions"]["installedBytes"], executable.stat().st_size + 7)
            rendered = report.render_markdown(result, index)
            self.assertIn("1 of the 2 indexed features", rendered)
            self.assertIn("not ready to merge", rendered)
            self.assertIn("| Sample |", rendered)
            self.assertNotIn("| Remaining |", rendered)
            self.assertIn("PR #1010", rendered)
            self.assertIn("visual editor", rendered)
            self.assertIn("Notch renderer", rendered)
            self.assertEqual(result["surfaceCustomization"]["layoutContractVersion"], 1)
            self.assertIn("Home card data and action adapters", result["surfaceCustomization"]["outstanding"])

    def test_stale_or_missing_fingerprints_cannot_produce_size_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            packages = Path(directory)
            (packages / "sample.json").write_text(json.dumps({"sourceFingerprint": "older-build"}))
            for fingerprints in [{}, {"sample": "current-build"}]:
                with self.assertRaisesRegex(ValueError, "Rebuild sample"):
                    report.build_report({}, Path("missing-app"), packages,
                        [{"id": "sample", "contractVersion": 1}], [{"id": "sample"}], fingerprints)

    def test_unindexed_or_duplicate_extensions_cannot_inflate_migration_counts(self):
        for index in [[{"id": "other"}], [{"id": "sample"}, {"id": "sample"}]]:
            with self.assertRaisesRegex(ValueError, "host index"):
                report.build_report({}, Path("missing"), Path("missing"), [{"id": "sample", "contractVersion": 1}], index)


if __name__ == "__main__":
    unittest.main()
