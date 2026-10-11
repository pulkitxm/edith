import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from size_report_filesystem import TreeSnapshot, digest_file, stable_file


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ClosedFilesystemTests(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)
        self.app = self.root / 'Fixture.app'
        self.app.mkdir()
        (self.app / 'payload').write_bytes(b'synthetic')

    def test_enumeration_errors_are_fatal_in_every_app_inventory(self):
        size = module('extension-size-report')
        host = module('extension-host-size-report')
        for operation in [size.measure_app, host.measure_host_components, host.tree_inventory]:
            with self.subTest(operation=operation.__name__), patch('size_report_filesystem.os.scandir', side_effect=PermissionError('synthetic')):
                with self.assertRaises(PermissionError):
                    operation(self.app)

    def test_unreadable_regular_files_and_changes_while_reading_are_fatal(self):
        size = module('extension-size-report')
        host = module('extension-host-size-report')
        for operation in [size.measure_app, host.measure_host_components, host.tree_inventory]:
            with self.subTest(operation=operation.__name__), patch('size_report_filesystem.os.open', side_effect=PermissionError('synthetic')):
                with self.assertRaises(PermissionError):
                    operation(self.app)
        path = self.app / 'payload'
        with self.assertRaisesRegex(ValueError, 'changed during reading'):
            with stable_file(path) as source:
                source.read()
                path.write_bytes(b'changed')

    def test_changed_added_deleted_and_replaced_entries_are_fatal(self):
        for change in ['add', 'delete', 'replace', 'write']:
            path = self.app / 'payload'
            path.write_bytes(b'synthetic')
            snapshot = TreeSnapshot(self.app)
            if change == 'add':
                (self.app / 'extra').write_bytes(b'extra')
            elif change == 'delete':
                path.unlink()
            elif change == 'replace':
                path.unlink()
                path.write_bytes(b'synthetic')
            else:
                path.write_bytes(b'changed')
            with self.subTest(change=change), self.assertRaises(ValueError):
                snapshot.verify()
            (self.app / 'extra').unlink(missing_ok=True)

    def test_special_files_and_escaping_links_are_rejected(self):
        special = self.app / 'special'
        os.mkfifo(special)
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            TreeSnapshot(self.app)
        special.unlink()
        (self.root / 'outside').write_bytes(b'outside')
        special.symlink_to(self.root / 'outside')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            TreeSnapshot(self.app)
        with self.assertRaisesRegex(ValueError, 'regular file'):
            digest_file(special)

    def test_orphan_zip_unknown_documents_and_wrong_checksums_are_rejected(self):
        size = module('extension-size-report')
        tests = module('test-extension-size-report')
        fixture = tests.ExtensionSizeReportTests()
        fixture.package(self.root)
        import shutil
        shutil.rmtree(self.app)
        for name in ['orphan.zip', 'unknown.json', 'sample.zip.sha256']:
            path = self.root / name
            path.write_bytes(b'invalid')
            with self.subTest(name=name), self.assertRaises(ValueError):
                size.measure_packages(self.root, ['sample'])
            path.unlink()

    def test_allowed_receipts_checksums_and_catalog_are_separately_measured(self):
        size = module('extension-size-report')
        tests = module('test-extension-size-report')
        import shutil
        shutil.rmtree(self.app)
        record = tests.ExtensionSizeReportTests().package(self.root)
        (self.root / 'sample.zip.sha256').write_text(record['sha256'] + '  sample.zip\n')
        (self.root / 'sample.ui-carrier-provenance.json').write_text('{}')
        (self.root / 'catalog-1.json').write_text('{}')
        assets = size.artifact_inventory(self.root, ['sample'], {'catalog-1.json': 'signedCatalog'})
        self.assertEqual({entry['category'] for entry in assets},
            {'packageMetadata', 'packageArchives', 'detachedChecksums', 'provenanceReceipts', 'signedCatalog'})
        self.assertEqual(len(size.measure_packages(self.root, ['sample'], {'catalog-1.json': 'signedCatalog'})), 1)


if __name__ == '__main__':
    unittest.main()
