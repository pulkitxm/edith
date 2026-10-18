import importlib.util
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('package_verify', Path(__file__).parent / 'hosted-managed-views/verify-package.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ManagedArchiveTests(unittest.TestCase):
    def test_crc_checked_regular_members_extract_with_original_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'synthetic.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                info = zipfile.ZipInfo('synthetic/Runtime')
                info.external_attr = (stat.S_IFREG | 0o755) << 16
                zipped.writestr(info, b'never-executed')
            target = root / 'expanded'
            self.assertEqual(module.extract_regular(archive, target, expected_root='synthetic'), 14)
            self.assertEqual((target / 'synthetic/Runtime').read_bytes(), b'never-executed')
            self.assertEqual((target / 'synthetic/Runtime').stat().st_mode & 0o777, 0o755)
            with self.assertRaises(ValueError):
                module.extract_regular(archive, target)

    def test_duplicate_traversal_symlink_and_wrong_root_reject_before_extraction(self):
        for names, mode in [(['synthetic/a', 'synthetic/a'], stat.S_IFREG), (['../escaped'], stat.S_IFREG), (['/absolute'], stat.S_IFREG), (['synthetic/a\\b'], stat.S_IFREG), (['synthetic/link'], stat.S_IFLNK), (['foreign/a'], stat.S_IFREG), (['synthetic/./a'], stat.S_IFREG)]:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / 'synthetic.zip'
                with zipfile.ZipFile(archive, 'w') as zipped:
                    for name in names:
                        info = zipfile.ZipInfo(name)
                        info.external_attr = (mode | 0o644) << 16
                        zipped.writestr(info, 'synthetic')
                target = root / 'expanded'
                with self.assertRaises(ValueError):
                    module.extract_regular(archive, target, expected_root='synthetic')
                self.assertFalse(target.exists())

    def test_crc_corruption_is_rejected_without_creating_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'synthetic.zip'
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as zipped:
                zipped.writestr('synthetic/resource', b'original-synthetic-resource')
            data = bytearray(archive.read_bytes())
            position = data.index(b'original-synthetic-resource')
            data[position] ^= 1
            archive.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'CRC'):
                module.extract_regular(archive, root / 'expanded')
            self.assertFalse((root / 'expanded').exists())

    def test_expanded_byte_limit_is_checked_before_crc_and_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'synthetic.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('synthetic/resource', b'12345')
            with self.assertRaisesRegex(ValueError, 'expanded byte bound'):
                module.extract_regular(archive, root / 'expanded', maximum_bytes=4)
            self.assertFalse((root / 'expanded').exists())


if __name__ == '__main__':
    unittest.main()
