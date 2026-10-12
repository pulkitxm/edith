import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('functional_carrier', Path(__file__).with_name('verify-role-package.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FunctionalCarrierVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='functional-carrier-')
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.host = self.root / 'Fixture.app'
        self.carrier = self.root / 'RoleCarrier/EdithExtensionCarrier'
        self.index = self.root / 'snapshot/index.json'
        self.host_executable = self.host / 'Contents/MacOS/Edith'
        self.host_index = self.host / 'Contents/Resources/index.json'
        for path, data, mode in [(self.carrier, b'synthetic carrier', 0o500), (self.index, b'[]', 0o600), (self.host_index, b'[]', 0o600), (self.host_executable, b'synthetic host', 0o500)]:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
            path.chmod(mode)
        self.source_root = self.root / 'source-keepAwake-1.0.0'
        self.source_root.mkdir(mode=0o700)
        self.document = {'schema': 1, 'kind': 'functional-role-carrier', 'root': str(self.root), 'owner': 'keepAwake', 'version': '1.0.0', 'sourceRoot': str(self.source_root), 'sourceCommit': 'a' * 40, 'sourceSHA256': 'b' * 64, 'toolchainSHA256': 'c' * 64, 'host': str(self.host), 'hostExecutableSHA256': self.digest(self.host_executable), 'carrier': self.record(self.carrier), 'index': self.record(self.index)}
        self.context = {'host': str(self.host), 'source_commit': 'a' * 40, 'host_hash': self.digest(self.host_executable), 'owner': 'keepAwake', 'version': '1.0.0'}

    def tearDown(self):
        self.temporary.cleanup()

    def digest(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def record(self, path):
        return {'path': str(path), 'sha256': self.digest(path), 'bytes': path.stat().st_size, 'mode': path.stat().st_mode & 0o777}

    def test_owned_context_can_supply_only_exact_carrier_input(self):
        provider = module.functional_carrier_provider(self.document, **self.context)
        self.assertEqual(provider()['sha256'], self.digest(self.carrier))
        self.assertEqual(provider()['path'], self.carrier)
        self.assertEqual(provider()['sourceCommit'], self.context['source_commit'])

    def test_foreign_owner_version_source_host_and_archive_are_rejected(self):
        for field, value in {'owner': 'calendar', 'version': '1.1.0', 'sourceCommit': 'd' * 40, 'hostExecutableSHA256': 'd' * 64, 'sourceRoot': str(self.root / 'foreign-archive'), 'host': str(self.root / 'Other.app')}.items():
            with self.subTest(field=field):
                document = copy.deepcopy(self.document)
                document[field] = value
                with self.assertRaises(ValueError):
                    module.functional_carrier_provider(document, **self.context)

    def test_malformed_authority_and_documents_are_rejected(self):
        for field, value in {'schema': True, 'kind': 'production', 'sourceSHA256': 'wrong', 'toolchainSHA256': 'wrong', 'carrier': None, 'index': {}}.items():
            with self.subTest(field=field):
                document = copy.deepcopy(self.document)
                document[field] = value
                with self.assertRaises(ValueError):
                    module.functional_carrier_provider(document, **self.context)
        with self.assertRaises(ValueError):
            module.functional_carrier_provider({**self.document, 'extra': True}, **self.context)

    def test_carrier_cannot_escape_selected_session(self):
        document = copy.deepcopy(self.document)
        document['carrier']['path'] = str(self.root.parent / 'foreign')
        with self.assertRaises(ValueError):
            module.functional_carrier_provider(document, **self.context)

    def test_symlinked_carrier_and_ancestor_are_rejected(self):
        self.carrier.unlink()
        self.carrier.symlink_to(self.host_executable)
        with self.assertRaises(ValueError):
            module.functional_carrier_provider(self.document, **self.context)
        self.carrier.unlink()
        self.carrier.parent.rmdir()
        self.carrier.parent.symlink_to(self.host_executable.parent, target_is_directory=True)
        with self.assertRaises((ValueError, FileNotFoundError)):
            module.functional_carrier_provider(self.document, **self.context)

    def test_hardlinked_or_other_writable_carrier_is_rejected(self):
        extra = self.root / 'extra-link'
        os.link(self.carrier, extra)
        with self.assertRaises(ValueError):
            module.functional_carrier_provider(self.document, **self.context)
        extra.unlink()
        self.carrier.chmod(0o522)
        with self.assertRaises(ValueError):
            module.functional_carrier_provider(self.document, **self.context)

    def test_changed_carrier_host_or_index_revokes_provider(self):
        for path in (self.carrier, self.host_executable, self.index, self.host_index):
            with self.subTest(path=path.name):
                provider = module.functional_carrier_provider(self.document, **self.context)
                original = path.read_bytes()
                mode = path.stat().st_mode & 0o777
                path.chmod(0o700)
                path.write_bytes(original + b'changed')
                path.chmod(mode)
                with self.assertRaises(ValueError):
                    provider()
                path.chmod(0o700)
                path.write_bytes(original)
                path.chmod(mode)

    def test_admitted_byte_bound_rejects_growth_shortening_and_oversize(self):
        for count in (self.document['carrier']['bytes'] - 1, self.document['carrier']['bytes'] + 1, 134217729):
            with self.subTest(bytes=count):
                document = copy.deepcopy(self.document)
                document['carrier']['bytes'] = count
                with self.assertRaises(ValueError):
                    module.functional_carrier_provider(document, **self.context)

    def test_host_index_must_match_source_index(self):
        self.host_index.write_bytes(b'[1]')
        with self.assertRaises(ValueError):
            module.functional_carrier_provider(self.document, **self.context)

    def test_session_must_remain_private(self):
        provider = module.functional_carrier_provider(self.document, **self.context)
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            provider()

    def test_production_cli_keeps_its_original_fixed_arguments(self):
        source = (Path(__file__).parent.parent / 'hosted-managed-views/verify-package.py').read_text()
        self.assertIn('if len(sys.argv) != 7:', source)
        self.assertIn('verify_package(*sys.argv[1:])', source)
        self.assertNotIn('os.environ', source)


if __name__ == '__main__':
    unittest.main()
