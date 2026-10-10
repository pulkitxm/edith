import importlib.util
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('chunk_artifact', Path(__file__).parent / 'hosted-managed-views/chunk-artifact.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ChunkArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / 'chunk.zip'

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, entries):
        with zipfile.ZipFile(self.path, 'w') as archive:
            for name, data in entries:
                archive.writestr(name, data)
        self.path.chmod(0o600)

    def test_exact_owned_result(self):
        self.archive([('result.json', '{"outcome":"passed"}')])
        self.assertEqual(module.read_chunk_artifact(self.path), {'outcome': 'passed'})

    def test_extra_traversal_array_and_expanded_budget_rejected(self):
        for entries in ([('result.json', '{}'), ('other', '{}')], [('../result.json', '{}')], [('result.json', '[]')], [('result.json', ' ' * (4 * 1024**2 + 1))]):
            self.archive(entries)
            with self.assertRaises((ValueError, zipfile.BadZipFile)):
                module.read_chunk_artifact(self.path)

    def test_symlink_hardlink_public_mode_fifo_rejected(self):
        self.archive([('result.json', '{}')])
        link = self.root / 'link'
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            module.read_chunk_artifact(link)
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(ValueError):
            module.read_chunk_artifact(self.path)
        link.unlink()
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            module.read_chunk_artifact(self.path)
        self.path.unlink()
        os.mkfifo(self.path, 0o600)
        with self.assertRaises(ValueError):
            module.read_chunk_artifact(self.path)

    def test_crc_and_entry_symlink_rejected(self):
        self.archive([('result.json', '{"unique":"value"}')])
        data = self.path.read_bytes().replace(b'value', b'wrong', 1)
        self.path.write_bytes(data)
        with self.assertRaises(zipfile.BadZipFile):
            module.read_chunk_artifact(self.path)
        with zipfile.ZipFile(self.path, 'w') as archive:
            entry = zipfile.ZipInfo('result.json')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o600) << 16
            archive.writestr(entry, '{}')
        with self.assertRaises(ValueError):
            module.read_chunk_artifact(self.path)


if __name__ == '__main__':
    unittest.main()
