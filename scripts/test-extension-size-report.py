import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("size_report", Path(__file__).with_name("extension-size-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ExtensionSizeReportTests(unittest.TestCase):
    def package(self, root, identifier="sample"):
        archive = root / f"{identifier}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
            zipped.writestr(f"{identifier}/payload", b"synthetic fixture" * 10)
        record = {
            "id": identifier,
            "version": "1.0.0",
            "downloadBytes": archive.stat().st_size,
            "installedBytes": 170,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        }
        (root / f"{identifier}.json").write_text(json.dumps(record))
        return record

    def test_app_symlinks_are_not_counted_twice(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Sample.app"
            app.mkdir()
            (app / "payload").write_bytes(b"synthetic fixture")
            (app / "alias").symlink_to("payload")
            measured = report.measure_app(app)
            self.assertEqual(measured["installedBytes"], 17)
            self.assertGreater(measured["comparisonZipBytes"], 17)

    def test_missing_app_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "app bundle is missing"):
            report.measure_app(Path("/missing-size-fixture.app"))

    def test_package_bytes_are_measured_from_the_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = self.package(root)
            expected = {**record, "releaseMetadataBytes": (root / "sample.json").stat().st_size}
            self.assertEqual(report.measure_packages(root, ["sample"]), [expected])

    def test_tampered_download_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root)
            with (root / "sample.zip").open("ab") as archive:
                archive.write(b"changed")
            with self.assertRaisesRegex(ValueError, "download size or checksum mismatch"):
                report.measure_packages(root, ["sample"])

    def test_incorrect_installed_size_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = self.package(root)
            record["installedBytes"] += 1
            (root / "sample.json").write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, "installed size or CRC mismatch"):
                report.measure_packages(root, ["sample"])

    def test_missing_and_unexpected_extensions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root)
            for expected in [[], ["sample", "missing"]]:
                with self.assertRaisesRegex(ValueError, "every extension"):
                    report.measure_packages(root, expected)

    def test_duplicate_extension_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root)
            duplicate = root / "duplicate"
            duplicate.mkdir()
            self.package(duplicate)
            with self.assertRaisesRegex(ValueError, "Duplicate package"):
                report.measure_packages(root, ["sample"])

    def test_totals_show_no_extensions_and_all_extensions(self):
        measured = report.compare(
            {"installedBytes": 1000, "zipBytes": 500},
            {"installedBytes": 750, "comparisonZipBytes": 400},
            [{"downloadBytes": 50, "installedBytes": 300}],
        )
        self.assertEqual(measured["savedPercent"], {"installedBytes": 25.0, "comparisonZipBytes": 20.0})
        self.assertEqual(measured["appWithAllExtensions"]["installedBytes"], 1050)
        self.assertEqual(measured["appWithAllExtensions"]["comparisonZipAndPackageBytes"], 450)


if __name__ == "__main__":
    unittest.main()
