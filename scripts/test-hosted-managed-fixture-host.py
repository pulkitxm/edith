import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('host_inventory', Path(__file__).with_name('hosted-managed-views') / 'fixture-host-inventory.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FixtureHostInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='edith-managed-host-')
        self.root = Path(self.directory.name).resolve()
        self.host = self.root / 'Fixture.app'
        self.payload = self.root / 'music'
        self.worker = self.payload / 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex'
        self.identifier = 'com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001'
        self.metadata = {'hostIdentifier': self.identifier, 'extensionID': 'music', 'version': '1.0.0', 'hostABI': 'edith-host-2', 'hostExecutableSHA256': hashlib.sha256(b'host-code').hexdigest()}
        self.make_bundle(self.host, {'CFBundleIdentifier': self.identifier, 'CFBundleExecutable': 'Edith'})
        for bundle, suffix in [(self.payload / 'ExtensionCarrier.app', ''), (self.worker, '.worker')]:
            self.make_bundle(bundle, {'CFBundleIdentifier': self.identifier + '.extension.music' + suffix, 'CFBundleExecutable': 'Edith', 'CFBundleShortVersionString': '1.0.0', 'EdithHostIdentifier': self.identifier, 'EdithHostABI': 'edith-host-2', 'EdithExecutableProvenance': self.metadata['hostExecutableSHA256'], 'EdithExtensionID': 'music', 'EdithExtensionVersion': '1.0.0', 'EdithHostExecutablePath': str(self.host / 'Contents/MacOS/Edith')})
        self.source_host = self.root / 'Source.app'
        self.make_bundle(self.source_host, {'CFBundleIdentifier': 'com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000002', 'CFBundleExecutable': 'Edith'})
        self.metadata.update(sourceHost=str(self.source_host), sourceHostExecutableSHA256=hashlib.sha256(b'host-code').hexdigest())
        self.entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True}

    def tearDown(self):
        self.directory.cleanup()

    def make_bundle(self, bundle, metadata):
        (bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
        (bundle / 'Contents/MacOS/Edith').write_bytes(b'host-code')
        resource = bundle / 'Contents/Resources/EdithHost_EdithHost.bundle/artwork.bin'
        resource.parent.mkdir(parents=True, exist_ok=True)
        resource.write_bytes(b'exact-synthetic-resource')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))

    def inventory(self):
        def identity(path):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            return {'signedSHA256': digest, 'rawUnsignedSHA256': digest, 'normalizedUnsignedSHA256': digest}
        return module.fixture_host_inventory(self.host, self.payload, self.metadata, identity=identity, verify=lambda path: None, entitlements=lambda path: self.entitlements)

    def test_exact_host_code_resources_metadata_and_closed_capabilities(self):
        proof = self.inventory()
        self.assertEqual(set(proof['copies']), {'carrier', 'worker'})
        self.assertFalse(proof['productionExecutableUnchangedProof'])
        self.assertFalse(proof['codeExecuted'])
        self.assertEqual(proof['workerEntitlements'], self.entitlements)

    def test_missing_extra_and_nonboolean_capabilities_reject(self):
        for capabilities in ({'com.apple.security.app-sandbox': True}, {**self.entitlements, 'com.apple.security.device.audio-input': True}, {**self.entitlements, 'com.apple.security.network.client': 1}):
            self.entitlements = capabilities
            with self.assertRaises(ValueError):
                self.inventory()

    def test_resource_or_executable_change_rejects_even_when_metadata_claims_original(self):
        path = self.worker / 'Contents/Resources/EdithHost_EdithHost.bundle/artwork.bin'
        path.write_bytes(b'changed')
        with self.assertRaises(ValueError):
            self.inventory()
        path.write_bytes(b'exact-synthetic-resource')
        (self.worker / 'Contents/MacOS/Edith').write_bytes(b'wrong-code')
        with self.assertRaises(ValueError):
            self.inventory()

    def test_sealed_host_path_and_version_cannot_be_rebound_silently(self):
        path = self.worker / 'Contents/Info.plist'
        original = plistlib.loads(path.read_bytes())
        for key, value in [('EdithHostExecutablePath', '/Applications/Edith.app/Contents/MacOS/Edith'), ('CFBundleShortVersionString', '2.0.0'), ('EdithHostIdentifier', 'com.pulkit.edith')]:
            path.write_bytes(plistlib.dumps({**original, key: value}))
            with self.assertRaises(ValueError):
                self.inventory()

    def test_clone_cannot_match_itself_while_differing_from_pinned_source(self):
        (self.source_host / 'Contents/MacOS/Edith').write_bytes(b'other-code')
        self.metadata['sourceHostExecutableSHA256'] = hashlib.sha256(b'other-code').hexdigest()
        with self.assertRaises(ValueError):
            self.inventory()
        (self.source_host / 'Contents/MacOS/Edith').write_bytes(b'host-code')
        (self.source_host / 'Contents/Resources/EdithHost_EdithHost.bundle/artwork.bin').write_bytes(b'changed-source')
        with self.assertRaises(ValueError):
            self.inventory()

    def test_symlink_resources_never_grant_ancestor_access(self):
        path = self.worker / 'Contents/Resources/EdithHost_EdithHost.bundle/artwork.bin'
        path.unlink()
        path.symlink_to(self.host / 'Contents/Resources/EdithHost_EdithHost.bundle/artwork.bin')
        with self.assertRaises(ValueError):
            self.inventory()


if __name__ == '__main__':
    unittest.main()
