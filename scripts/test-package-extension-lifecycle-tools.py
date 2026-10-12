import json
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from package_extension_lifecycle_tools import BUNDLE, FILES, RECEIPT, package_tools, verify_tools


class LifecycleToolsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        revision = patch('package_extension_lifecycle_tools.subprocess.check_output', return_value='a' * 40 + '\n')
        revision.start()
        self.addCleanup(revision.stop)
        self.host = self.root / 'local/Edith.app'
        self.host_products = self.root / 'Packages/EdithHost/.build/arm64/debug'
        self.marketplace_products = self.root / 'Packages/ExtensionMarketplace/.build/arm64/debug'
        self.output = self.root / 'local/extension-tools'
        self.index = json.dumps([{'id': 'owner' + str(index), 'title': 'Synthetic', 'symbolName': 'circle', 'category': 'utility'} for index in range(39)]).encode()
        self.write('Extensions/manifest.json', json.dumps([{'id': 'owner' + str(index)} for index in range(39)]).encode())
        self.write('Packages/EdithHost/Sources/EdithHostCore/Resources/index.json', self.index)
        self.write(self.host / 'Contents/Resources/index.json', self.index)
        self.write(self.host_products / FILES[0], b'synthetic lifecycle executable', 0o751)
        self.write(self.marketplace_products / FILES[1], b'synthetic marketplace executable', 0o755)
        self.write(self.host_products / FILES[2], self.index)
        self.write(self.host_products / FILES[3], b'synthetic carrier executable', 0o755)
        executable = b'synthetic minimal host'
        self.write(self.host / 'Contents/MacOS/Edith', executable, 0o755)
        self.write(self.host.parent / 'build-metadata.json', json.dumps({'sourceCommit': 'a' * 40, 'sourceTreeDirty': False, 'hostExecutableSHA256': hashlib.sha256(executable).hexdigest()}).encode())

    def write(self, path, data, mode=0o644):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def package(self):
        return package_tools(self.root, self.host, self.host_products, self.marketplace_products, self.output)

    def test_copies_executables_and_adjacent_index_with_exact_permissions(self):
        receipt = self.package()
        self.assertEqual(verify_tools(self.root, self.host, self.output), receipt)
        self.assertEqual((self.output / FILES[2]).read_bytes(), self.index)
        for name, source in [(FILES[0], self.host_products / FILES[0]), (FILES[1], self.marketplace_products / FILES[1]), (FILES[3], self.host_products / FILES[3])]:
            self.assertEqual((self.output / name).read_bytes(), source.read_bytes())
            self.assertEqual((self.output / name).stat().st_mode & 0o777, source.stat().st_mode & 0o777)
        self.assertEqual(set(receipt['files']), set(FILES))

    def test_missing_sibling_bundle_fails_before_creating_output(self):
        (self.host_products / FILES[2]).unlink()
        with self.assertRaises(FileNotFoundError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_stale_built_or_frozen_index_is_rejected(self):
        for path in [self.host_products / FILES[2], self.host / 'Contents/Resources/index.json']:
            original = path.read_bytes()
            path.write_bytes(b'[]')
            with self.assertRaisesRegex(ValueError, 'index'):
                self.package()
            self.assertFalse(self.output.exists())
            path.write_bytes(original)

    def test_source_index_must_match_all39_manifest_owners(self):
        self.write('Extensions/manifest.json', json.dumps([{'id': 'other' + str(index)} for index in range(39)]).encode())
        with self.assertRaisesRegex(ValueError, 'manifest'):
            self.package()
        self.assertFalse(self.output.exists())

    def test_duplicate_or_missing_manifest_owners_are_rejected(self):
        for rows in [[{'id': 'owner0'}] * 39, [{'id': 'owner' + str(index)} for index in range(38)]]:
            self.write('Extensions/manifest.json', json.dumps(rows).encode())
            with self.assertRaises(ValueError):
                self.package()
            self.assertFalse(self.output.exists())

    def test_symlink_file_and_ancestor_are_rejected(self):
        executable = self.host_products / FILES[0]
        saved = executable.with_suffix('.original')
        executable.rename(saved)
        executable.symlink_to(saved)
        with self.assertRaises(ValueError):
            self.package()
        executable.unlink()
        saved.rename(executable)
        linked = self.root / 'linked-products'
        linked.symlink_to(self.host_products, target_is_directory=True)
        with self.assertRaises(ValueError):
            package_tools(self.root, self.host, linked, self.marketplace_products, self.output)
        self.assertFalse(self.output.exists())

    def test_hard_links_and_nonregular_inputs_are_rejected(self):
        executable = self.host_products / FILES[0]
        linked = executable.with_suffix('.linked')
        os.link(executable, linked)
        with self.assertRaises(ValueError):
            self.package()
        linked.unlink()
        executable.unlink()
        os.mkfifo(executable)
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_foreign_user_owned_paths_are_rejected(self):
        with patch('package_extension_lifecycle_tools.os.getuid', return_value=os.getuid() + 1):
            with self.assertRaisesRegex(ValueError, 'owned, regular'):
                self.package()
        self.assertFalse(self.output.exists())

    def test_mutable_permissions_and_nonexecutable_tool_are_rejected(self):
        executable = self.host_products / FILES[0]
        for mode in [0o777, 0o644]:
            executable.chmod(mode)
            with self.assertRaises(ValueError):
                self.package()
            self.assertFalse(self.output.exists())

    def test_foreign_workspace_input_and_existing_output_are_not_modified(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        with self.assertRaisesRegex(ValueError, 'source workspace'):
            package_tools(self.root, self.host, Path(temporary.name).resolve(), self.marketplace_products, self.output)
        self.output.mkdir()
        sentinel = self.output / 'sentinel'
        sentinel.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'new directory'):
            self.package()
        self.assertEqual(sentinel.read_bytes(), b'keep')

    def test_restored_tool_and_index_tampering_fails_verification(self):
        self.package()
        for name in FILES:
            path = self.output / name
            original = path.read_bytes()
            path.write_bytes(original + b'tampered')
            with self.assertRaisesRegex(ValueError, 'receipt'):
                verify_tools(self.root, self.host, self.output)
            path.write_bytes(original)

    def test_receipt_cannot_rebind_an_index_to_foreign_bytes(self):
        self.package()
        receipt = json.loads((self.output / RECEIPT).read_text())
        receipt['indexSHA256'] = '0' * 64
        (self.output / RECEIPT).write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'frozen source index'):
            verify_tools(self.root, self.host, self.output)

    def test_restored_package_rejects_extra_files_and_symlink_resources(self):
        self.package()
        extra = self.output / BUNDLE / 'foreign'
        extra.write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError, 'unexpected files'):
            verify_tools(self.root, self.host, self.output)
        extra.unlink()
        index = self.output / FILES[2]
        index.unlink()
        index.symlink_to(self.host / 'Contents/Resources/index.json')
        with self.assertRaises(ValueError):
            verify_tools(self.root, self.host, self.output)


    def test_source_and_frozen_host_cannot_be_rebound_after_packaging(self):
        self.package()
        for key, value in [('sourceCommit', 'b' * 40), ('hostExecutableSHA256', '0' * 64), ('schema', 1)]:
            receipt_path = self.output / RECEIPT
            original = receipt_path.read_bytes()
            receipt = json.loads(original)
            receipt[key] = value
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                verify_tools(self.root, self.host, self.output)
            receipt_path.write_bytes(original)
        self.write(self.host / 'Contents/MacOS/Edith', b'changed host', 0o755)
        with self.assertRaisesRegex(ValueError, 'frozen source'):
            verify_tools(self.root, self.host, self.output)

    def test_carrier_must_be_present_owned_executable_and_single_link(self):
        carrier = self.host_products / FILES[3]
        original = carrier.read_bytes()
        carrier.unlink()
        with self.assertRaises(FileNotFoundError):
            self.package()
        carrier.write_bytes(original)
        for mode in (0o644, 0o777):
            carrier.chmod(mode)
            with self.assertRaises(ValueError):
                self.package()
        carrier.chmod(0o755)
        link = carrier.with_suffix('.linked')
        os.link(carrier, link)
        with self.assertRaises(ValueError):
            self.package()
        link.unlink()
        carrier.unlink()
        carrier.symlink_to(self.host_products / FILES[0])
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_dirty_or_foreign_frozen_metadata_is_rejected(self):
        path = self.host.parent / 'build-metadata.json'
        original = path.read_bytes()
        for key, value in [('sourceCommit', 'b' * 40), ('sourceTreeDirty', True), ('hostExecutableSHA256', '0' * 64)]:
            metadata = json.loads(original)
            metadata[key] = value
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, 'frozen source'):
                self.package()
            self.assertFalse(self.output.exists())

    def test_carrier_only_input_reuses_source_seals_without_harness_payload(self):
        receipt = package_tools(self.root, self.host, None, None, self.output, self.host_products, True)
        self.assertEqual(receipt['kind'], 'carrier')
        self.assertEqual(set(receipt['files']), set(FILES[2:]))
        self.assertFalse((self.output / FILES[0]).exists())
        self.assertEqual(verify_tools(self.root, self.host, self.output, carrier=True), receipt)
        with self.assertRaises(ValueError):
            verify_tools(self.root, self.host, self.output)
        path = self.output / FILES[3]
        path.write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            verify_tools(self.root, self.host, self.output, carrier=True)

if __name__ == '__main__':
    unittest.main()
