import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'apps/companion/prepare-pdf-extract.py'
SPEC = importlib.util.spec_from_file_location('pdf_source_preparation', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture_sources():
    values = {name: ('synthetic font source ' + name).encode() for name in MODULE.SOURCE_FILES}
    values['Cargo.toml.orig'] = b'version = "0.12.1"\nlopdf = {version = "0.42", default-features = false, features = ["wasm_js"]}\nlicense = "MIT"\n'
    values['src/lib.rs'] = b'let contents = doc.get_page_content(object_id).unwrap();\n'
    values['LICENSE'] = b'synthetic license preserved\n'
    return values


def archive(values, extra=None):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:gz', format=tarfile.USTAR_FORMAT) as output:
        for name, value in values.items():
            member = tarfile.TarInfo('pdf-extract-0.12.1/' + name)
            member.size = len(value)
            output.addfile(member, io.BytesIO(value))
        if extra is not None:
            output.addfile(extra, io.BytesIO(b'x' * extra.size))
    return result.getvalue()


def unpack(data):
    return MODULE.source_files(data, hashlib.sha256(data).hexdigest())


class PDFSourcePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pdf-source-')
        self.root = Path(os.path.realpath(self.temporary.name))
        os.chmod(self.root, 0o700)
        self.values = fixture_sources()
        self.data = archive(self.values)
        self.files = unpack(self.data)
        self.target = self.root / 'pdf-extract'
        self.expected = {name: hashlib.sha256(value).hexdigest() for name, value in self.files.items()}

    def tearDown(self):
        self.temporary.cleanup()

    def test_reviewed_adaptations_preserve_all_font_bytes_and_license(self):
        for name in MODULE.SOURCE_FILES:
            if name not in ('Cargo.toml.orig', 'src/lib.rs'):
                self.assertEqual(self.files[name], self.values[name])
        self.assertEqual(self.files['LICENSE'], self.values['LICENSE'])
        self.assertIn(b'version = "0.13.0"', self.files['Cargo.toml'])
        self.assertIn(b'lopdf = {version = "0.45"', self.files['Cargo.toml'])
        self.assertEqual(self.files['src/lib.rs'], b'let contents = doc.get_page_content(object_id);\n')
        self.assertNotIn('Cargo.toml.orig', self.files)

    def test_wrong_checksum_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.source_files(self.data, '0' * 64)

    def test_missing_extractor_is_rejected(self):
        self.values.pop('src/lib.rs')
        with self.assertRaisesRegex(ValueError, 'Missing'):
            unpack(archive(self.values))

    def test_changed_or_duplicate_adaptation_anchor_is_rejected(self):
        for value in (b'changed upstream API', self.values['src/lib.rs'] * 2):
            with self.subTest(value=value):
                self.values['src/lib.rs'] = value
                with self.assertRaisesRegex(ValueError, 'adaptation'):
                    unpack(archive(self.values))

    def test_traversal_absolute_backslash_and_duplicate_members_are_rejected(self):
        for name in ('pdf-extract-0.12.1/../escape', '/escape', 'pdf-extract-0.12.1/a\\b', 'pdf-extract-0.12.1/src/lib.rs'):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.size = 1
                with self.assertRaises(ValueError):
                    unpack(archive(self.values, member))

    def test_links_directories_and_special_members_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                member = tarfile.TarInfo('pdf-extract-0.12.1/unsafe')
                member.type = kind
                member.linkname = 'src/lib.rs'
                with self.assertRaisesRegex(ValueError, 'member'):
                    unpack(archive(self.values, member))

    def test_large_archive_is_rejected_before_open(self):
        data = b'x' * (MODULE.MAXIMUM_BYTES + 1)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.source_files(data, hashlib.sha256(data).hexdigest())

    def test_compressed_expansion_is_bounded_before_tar_parsing(self):
        data = gzip.compress(b'x' * (MODULE.MAXIMUM_BYTES * 2 + 1))
        with self.assertRaisesRegex(ValueError, 'expanded'):
            unpack(data)

    def test_install_is_private_complete_and_repeat_verifiable(self):
        MODULE.install(self.target, self.files)
        MODULE.snapshot(self.target, self.expected)
        MODULE.snapshot(self.target, self.expected)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o700)
        for name in self.files:
            self.assertEqual(stat.S_IMODE((self.target / name).stat().st_mode), 0o600)

    def test_changed_current_output_is_rejected_without_replacement(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'src/lib.rs'
        path.write_bytes(b'changed current output')
        with self.assertRaisesRegex(ValueError, 'changed'):
            MODULE.snapshot(self.target, self.expected)
        self.assertEqual(path.read_bytes(), b'changed current output')

    def test_missing_and_extra_current_output_is_rejected(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'README.md'
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            MODULE.snapshot(self.target, self.expected)
        path.write_bytes(self.files['README.md'])
        os.chmod(path, 0o600)
        (self.target / 'extra').write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            MODULE.snapshot(self.target, self.expected)

    def test_unsafe_generated_file_and_parent_are_rejected(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'README.md'
        os.chmod(path, 0o644)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        os.chmod(path, 0o600)
        os.link(path, self.root / 'hardlink')
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        (self.root / 'hardlink').unlink()
        path.unlink()
        path.symlink_to(self.root / 'outside')
        with self.assertRaises(OSError):
            MODULE.snapshot(self.target, self.expected)

    def test_symlink_or_writable_directory_is_rejected(self):
        MODULE.install(self.target, self.files)
        os.chmod(self.target / 'src', 0o755)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        alias = self.root / 'alias'
        alias.symlink_to(self.target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(alias, self.expected)

    def test_access_time_changes_do_not_invalidate_stable_file_identity(self):
        MODULE.install(self.target, self.files)
        before = (self.target / 'README.md').stat()
        with patch.object(MODULE.os, 'fstat', wraps=os.fstat):
            MODULE.snapshot(self.target, self.expected)
        after = (self.target / 'README.md').stat()
        self.assertEqual(MODULE.file_identity(before), MODULE.file_identity(after))


if __name__ == '__main__':
    unittest.main()
