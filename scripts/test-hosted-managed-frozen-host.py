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
            for row in [
                ('local/minimal-host/Edith.app/Contents/MacOS/Edith', b'synthetic-code', None),
                ('local/minimal-host/Edith.app/Contents/Info.plist', b'synthetic-plist', None),
                ('local/minimal-host/build-metadata.json', b'{}', None),
                ('local/extension-tools/unused', b'not-extracted', None),
                *extra,
            ]:
                name, contents, kind, *attributes = row
                entry = tarfile.TarInfo(name)
                entry.mode = attributes[1] if len(attributes) > 1 else 0o600
                entry.size = len(contents)
                if kind:
                    entry.type = kind
                    entry.linkname = attributes[0] if attributes else '../../foreign'
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

    def test_release_tree_selection_preserves_default_and_rejects_unknown_tree(self):
        release = [
            ('local/extension-release-host/Edith.app/Contents/MacOS/Edith', b'signed-synthetic-code', None),
            ('local/extension-release-host/Edith.app/Contents/Info.plist', b'signed-synthetic-plist', None),
            ('local/extension-release-host/build-metadata.json', b'{"signature":"synthetic"}', None),
        ]
        artifact = self.archive(release)
        module.unpack_frozen_host(artifact, self.output)
        self.assertEqual((self.output / 'Edith.app/Contents/MacOS/Edith').read_bytes(), b'synthetic-code')
        signed = self.root / 'signed'
        signed.mkdir(mode=0o700)
        module.unpack_frozen_host(artifact, signed, 'extension-release-host')
        self.assertEqual((signed / 'Edith.app/Contents/MacOS/Edith').read_bytes(), b'signed-synthetic-code')
        for tree in ['../extension-release-host', 'extension-tools', '', 'local/extension-release-host']:
            with self.assertRaises(ValueError):
                module.unpack_frozen_host(artifact, self.root / 'missing', tree)
        unsafe = self.root / 'unsafe'
        unsafe.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.archive(release + [('local/extension-release-host/../foreign', b'x', None)]), unsafe, 'extension-release-host')

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

    def release(self):
        return [
            ('local/extension-release-host/Edith.app/Contents/MacOS/Edith', b'signed-code', None, '', 0o755),
            ('local/extension-release-host/Edith.app/Contents/Info.plist', b'signed-plist', None),
            ('local/extension-release-host/build-metadata.json', b'{}', None),
            ('local/extension-release-host/Edith.app/Contents/MacOS/ed', b'', tarfile.SYMTYPE, '../Resources/ed-launcher'),
            ('local/extension-release-host/Edith.app/Contents/Resources/ed-launcher', b'signed-launcher', None, '', 0o755),
        ]

    def test_signed_launcher_link_preserves_bytes_target_and_executable_modes(self):
        artifact = self.archive(self.release())
        receipt = module.unpack_frozen_host(artifact, self.output, 'extension-release-host')
        launcher = self.output / 'Edith.app/Contents/MacOS/ed'
        self.assertEqual(launcher.readlink(), Path('../Resources/ed-launcher'))
        self.assertEqual(launcher.read_bytes(), b'signed-launcher')
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
        executable = self.output / 'Edith.app/Contents/MacOS/Edith'
        self.assertEqual(executable.read_bytes(), b'signed-code')
        self.assertEqual(executable.stat().st_mode & 0o777, 0o755)
        self.assertFalse(receipt['codeExecuted'])
        minimal = self.root / 'minimal'
        minimal.mkdir(mode=0o700)
        module.unpack_frozen_host(artifact, minimal)
        self.assertFalse((minimal / 'Edith.app/Contents/MacOS/ed').exists())

    def test_only_exact_launcher_link_and_regular_target_are_accepted(self):
        link = self.release()[3]
        target = self.release()[4]
        cases = [
            [*self.release()[:3], (*link[:3], '../../../foreign'), target],
            [*self.release()[:3], (*link[:3], '/tmp/foreign'), target],
            [*self.release()[:3], ('local/extension-release-host/Edith.app/Contents/MacOS/foreign', *link[1:]), target],
            [*self.release()[:3], (link[0], b'', tarfile.LNKTYPE, '../Resources/ed-launcher'), target],
            [*self.release()[:4], (target[0], b'', tarfile.SYMTYPE, '../MacOS/Edith')],
            [*self.release()[:4], (target[0], b'', tarfile.DIRTYPE)],
            [*self.release(), (target[0], b'x', None)],
            [*self.release(), (link[0] + '/child', b'x', None)],
            [*self.release(), ('local/extension-release-host/Edith.app/Contents/MacOS', b'x', None)],
            [*self.release(), ('local/extension-release-host/Edith.app/Contents/Frameworks/Sparkle.framework/Sparkle', b'', tarfile.SYMTYPE, 'Versions/Current/Sparkle')],
        ]
        for index, rows in enumerate(cases):
            with self.subTest(index=index):
                output = self.root / f'reject-{index}'
                output.mkdir(mode=0o700)
                with self.assertRaises(ValueError):
                    module.unpack_frozen_host(self.archive(rows), output, 'extension-release-host')
                self.assertFalse((output / 'Edith.app/Contents/MacOS/ed').is_symlink())
        missing = self.root / 'missing-target'
        missing.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            module.unpack_frozen_host(self.archive(self.release()[:4]), missing, 'extension-release-host')

    def test_launcher_cannot_clobber_source_or_precede_an_archived_child(self):
        sentinel = self.root / 'source'
        sentinel.write_bytes(b'preserved-source')
        for index, rows in enumerate([
            self.release() + [('local/extension-release-host/Edith.app/Contents/MacOS/ed', b'replacement', None)],
            [*self.release()[:3], (self.release()[3][0] + '/child', b'x', None), *self.release()[3:]],
            [*self.release()[:3], (*self.release()[3][:3], str(sentinel)), self.release()[4]],
        ]):
            output = self.root / f'clobber-{index}'
            output.mkdir(mode=0o700)
            with self.assertRaises(ValueError):
                module.unpack_frozen_host(self.archive(rows), output, 'extension-release-host')
            self.assertEqual(sentinel.read_bytes(), b'preserved-source')


if __name__ == '__main__':
    unittest.main()
