import importlib.util
import io
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('frozen', Path(__file__).with_name('hosted-managed-views') / 'frozen-host-artifact.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrozenHostArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='edith-managed-frozen-')
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / 'host'
        self.output.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, extra=(), outer='host.tar.gz'):
        compressed = io.BytesIO()
        with tarfile.open(fileobj=compressed, mode='w:gz') as tar:
            for name, contents, kind in [
                ('local/minimal-host/Edith.app/Contents/MacOS/Edith', b'synthetic-code', None),
                ('local/minimal-host/Edith.app/Contents/Info.plist', b'synthetic-plist', None),
                ('local/minimal-host/build-metadata.json', b'{}', None),
                ('local/extension-tools/unused', b'not-extracted', None),
                *extra,
            ]:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o600
                entry.size = len(contents)
                if kind:
                    entry.type = kind
                    entry.linkname = '../../foreign'
                tar.addfile(entry, io.BytesIO(contents))
        path = self.root / 'artifact.zip'
        with zipfile.ZipFile(path, 'w') as zip:
            zip.writestr(outer, compressed.getvalue())
        return path

    def test_actual_zip_tar_selects_only_minimal_host_and_never_executes_it(self):
        receipt = module.unpack_frozen_host(self.archive(), self.output)
        self.assertFalse(receipt['codeExecuted'])
        self.assertEqual(receipt['extractedFiles'], 3)
        self.assertEqual((self.output / 'Edith.app/Contents/MacOS/Edith').read_bytes(), b'synthetic-code')
        self.assertFalse((self.output / 'extension-tools').exists())
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.root / 'artifact.zip', self.output)

    def test_traversal_duplicate_links_and_unexpected_tree_fail_closed(self):
        for extra in [('../../foreign', b'x', None), ('local/minimal-host/../foreign', b'x', None), ('local/minimal-host/build-metadata.json', b'x', None), ('local/minimal-host/link', b'', tarfile.SYMTYPE), ('local/user-data/private', b'x', None)]:
            with self.subTest(extra=extra[0]):
                output = self.root / ('out' + str(len(list(self.root.iterdir()))))
                output.mkdir(mode=0o700)
                with self.assertRaises(ValueError):
                    module.unpack_frozen_host(self.archive([extra]), output)

    def test_outer_asset_name_output_mode_and_symlink_do_not_gain_access(self):
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.archive(outer='other.tar.gz'), self.output)
        self.output.chmod(0o740)
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.archive(), self.output)
        link = self.root / 'link'
        link.symlink_to(self.output)
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.root / 'artifact.zip', link)


if __name__ == '__main__':
    unittest.main()
