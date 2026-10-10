import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from host_build_metadata import executable_hash, load_metadata, write_metadata
from verify_shipping_host import inspect_cli


class HostBuildMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.bundle('source', b'synthetic original executable')
        self.destination = self.bundle('destination', b'synthetic resigned executable')

    def bundle(self, directory, contents):
        bundle = self.root / directory / 'Edith.app'
        executable = bundle / 'Contents/MacOS/Edith'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(contents)
        return bundle

    def test_repackaging_preserves_source_provenance_and_binds_the_resigned_executable(self):
        original = {'sourceCommit': 'synthetic-source', 'sourceTreeDirty': False,
                    'configuration': 'Release', 'signature': 'ad-hoc',
                    'hostExecutableSHA256': executable_hash(self.source)}
        write_metadata(self.source, original, 'ad-hoc')
        source = load_metadata(self.source)
        write_metadata(self.destination, source, 'Developer ID')
        packaged = load_metadata(self.destination)
        self.assertEqual(packaged['sourceCommit'], 'synthetic-source')
        self.assertIs(packaged['sourceTreeDirty'], False)
        self.assertEqual(packaged['configuration'], 'Release')
        self.assertEqual(packaged['signature'], 'Developer ID')
        self.assertEqual(packaged['hostExecutableSHA256'], executable_hash(self.destination))
        self.assertNotEqual(packaged['hostExecutableSHA256'], source['hostExecutableSHA256'])
        self.assertEqual(source, original)

    def test_changed_executable_or_stale_receipt_rejects_source_provenance(self):
        write_metadata(self.source, {'sourceCommit': 'synthetic-source'}, 'ad-hoc')
        (self.source / 'Contents/MacOS/Edith').write_bytes(b'changed executable')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            load_metadata(self.source)

    def test_missing_source_receipt_does_not_reuse_old_destination_metadata(self):
        self.assertIsNone(load_metadata(self.source))
        write_metadata(self.destination, {'sourceCommit': 'older-source'}, 'ad-hoc')
        write_metadata(self.destination, None, 'ad-hoc')
        self.assertIsNone(load_metadata(self.destination))

    def test_dirty_source_is_recorded_without_claiming_a_clean_build(self):
        write_metadata(self.source, {'sourceTreeDirty': True}, 'ad-hoc')
        self.assertIs(load_metadata(self.source)['sourceTreeDirty'], True)

    def test_shipping_verification_checks_original_plain_and_explicit_json_version_commands(self):
        with patch('verify_shipping_host.run', side_effect=['1.2.3\n', json.dumps({'version': '1.2.3', 'appRunning': False})]) as run:
            inspect_cli('/synthetic/Edith', '1.2.3')
            self.assertEqual(run.call_args_list[0].args, ('/synthetic/Edith', '--version'))
            self.assertEqual(run.call_args_list[1].args, ('/synthetic/Edith', 'version', '--json'))

    def test_shipping_verification_rejects_either_wrong_version(self):
        for replies in [['0.0.0\n'], ['1.2.3\n', json.dumps({'version': '0.0.0'})]]:
            with patch('verify_shipping_host.run', side_effect=replies):
                with self.assertRaises(AssertionError):
                    inspect_cli('/synthetic/Edith', '1.2.3')


if __name__ == '__main__':
    unittest.main()
