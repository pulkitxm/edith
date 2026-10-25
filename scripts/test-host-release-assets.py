import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from host_release_assets import ASSETS, EXTENSIONS, validate_assets


class HostReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = 'a' * 40
        self.url = 'https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg'
        self.dmg = self.root / 'Edith.dmg'
        self.dmg.write_bytes(b'synthetic DMG')
        self.appcast = self.root / 'appcast.xml'
        signature = base64.b64encode(bytes(64)).decode()
        self.appcast.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>123</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure url="{self.url}" length="13" sparkle:edSignature="{signature}" /></item></channel></rss>')
        self.metadata = {'sourceCommit': self.source, 'sourceTreeDirty': False, 'configuration': 'Release', 'optimization': 'Osize', 'linkTimeOptimization': 'full', 'architecture': 'arm64', 'hostExecutableSHA256': 'b' * 64}
        self.toolchain = {'schema': 1, 'sourceCommit': self.source, 'hostExecutableSHA256': 'b' * 64, 'xcode': 'Xcode 26.0\nBuild version 17A400', 'sdk': '26.0', 'builderSignature': 'ad-hoc'}
        self.proof = {'schema': 1, 'sourceCommit': self.source, 'version': '1.2.3', 'build': '123', 'installedBytes': 1234, 'extensionPayloadBytes': 0, 'indexedExtensions': EXTENSIONS, 'indexSHA256': 'c' * 64, 'hostExecutableSHA256': 'b' * 64, 'certificateCategory': 'Apple Development', 'teamIdentifier': 'ABCDEFGHIJ', 'verifiedDesignatedRequirement': 'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"', 'deepStrictSignatureVerified': True, 'dmgBytes': 13, 'dmgSHA256': hashlib.sha256(self.dmg.read_bytes()).hexdigest(), 'dmgURL': self.url, 'appcastSHA256': hashlib.sha256(self.appcast.read_bytes()).hexdigest(), 'sparklePublicKey': base64.b64encode(bytes(32)).decode(), 'sparkleEd25519Verified': True, 'notarization': 'skipped', 'publicationVerified': False, 'managedViewsVerified': False, 'hardwareVerified': False, 'sourceQualification': 'clean', 'workflowSourceCommit': self.source, 'sourceMode': 'current-workflow-source'}
        self.documents = {'host-release-proof.json': self.proof, 'build-metadata.json': self.metadata, 'toolchain-provenance.json': self.toolchain}
        self.write()

    def write(self):
        for name, value in self.documents.items():
            (self.root / name).write_text(json.dumps(value))

    def validate(self, **options):
        return validate_assets(self.root, 'synthetic/fixture', 'v1.2.3', self.source, **options)

    def test_accepts_exact_assets_stamp_state_and_separate_rebuild_source(self):
        self.assertEqual(self.validate(), ASSETS)
        self.metadata['sourceTreeDirty'] = True
        self.proof['sourceQualification'] = 'release-version-stamp-only'
        self.write()
        self.assertEqual(self.validate(), ASSETS)
        self.proof.update(sourceMode='tag-rebuild', workflowSourceCommit='d' * 40)
        self.write()
        self.assertEqual(self.validate(rebuild=True), ASSETS)
        with self.assertRaises(ValueError):
            self.validate()

    def test_all_receipts_reject_duplicate_unknown_and_missing_fields(self):
        for name, original in self.documents.items():
            path = self.root / name
            for field in original:
                missing = dict(original)
                del missing[field]
                for text in [json.dumps(missing), json.dumps(original)[:-1] + ',' + json.dumps(field) + ':' + json.dumps(original[field]) + '}']:
                    with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                        path.write_text(text)
                        self.validate()
            with self.subTest(name=name), self.assertRaises(ValueError):
                path.write_text(json.dumps({**original, 'private': 'unexpected'}))
                self.validate()
            self.write()

    def test_receipt_types_bounds_and_relationships_fail_closed(self):
        changes = {
            'host-release-proof.json': [{'schema': True}, {'installedBytes': True}, {'installedBytes': 10000000}, {'installedBytes': 0}, {'indexedExtensions': 38}, {'extensionPayloadBytes': 1}, {'sourceCommit': 'd' * 40}, {'hostExecutableSHA256': 'd' * 64}, {'indexSHA256': 'bad'}, {'workflowSourceCommit': 'd' * 40}, {'sourceMode': 'tag-rebuild'}, {'sourceQualification': 'release-version-stamp-only'}, {'version': '1.2.4'}, {'build': 123}, {'build': '1' * 33}, {'dmgBytes': 12}, {'dmgSHA256': 'd' * 64}, {'dmgURL': 'https://foreign/Edith.dmg'}, {'appcastSHA256': 'd' * 64}, {'sparklePublicKey': 'bad'}, {'deepStrictSignatureVerified': 1}, {'sparkleEd25519Verified': False}, {'publicationVerified': True}, {'managedViewsVerified': 0}, {'hardwareVerified': None}, {'certificateCategory': 'ad-hoc'}, {'teamIdentifier': 'foreign'}, {'verifiedDesignatedRequirement': 'foreign'}, {'notarization': 'pending'}],
            'build-metadata.json': [{'sourceCommit': 'd' * 40}, {'hostExecutableSHA256': 'd' * 64}, {'configuration': 'Debug'}, {'architecture': []}, {'sourceTreeDirty': 0}],
            'toolchain-provenance.json': [{'schema': True}, {'sourceCommit': 'd' * 40}, {'hostExecutableSHA256': 'd' * 64}, {'xcode': 'Xcode 26.0\nBuild version ' + 'A' * 257}, {'xcode': None}, {'sdk': '1.' + '0' * 33}, {'sdk': 26}, {'builderSignature': 'Apple Development'}],
        }
        for name, cases in changes.items():
            original = self.documents[name]
            for change in cases:
                with self.subTest(name=name, change=change), self.assertRaises(ValueError):
                    (self.root / name).write_text(json.dumps({**original, **change}))
                    self.validate()
            self.write()

    def test_actual_dmg_appcast_and_asset_file_identity_are_required(self):
        self.dmg.write_bytes(b'changed image')
        with self.assertRaises(ValueError):
            self.validate()
        self.dmg.write_bytes(b'synthetic DMG')
        xml = self.appcast.read_text()
        for changed in [xml.replace(self.url, 'https://foreign/Edith.dmg'), xml.replace('length="13"', 'length="14"'), xml.replace('>123<', '>124<'), xml.replace('>1.2.3<', '>1.2.4<'), xml.replace('</item>', '<enclosure /></item>'), xml.replace('sparkle:edSignature=', 'signature='), '<!DOCTYPE rss>' + xml]:
            self.appcast.write_text(changed)
            self.proof['appcastSHA256'] = hashlib.sha256(self.appcast.read_bytes()).hexdigest()
            self.write()
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.validate()
        self.appcast.write_text(xml)
        self.proof['appcastSHA256'] = hashlib.sha256(self.appcast.read_bytes()).hexdigest()
        self.write()
        for name in ASSETS:
            path = self.root / name
            content = path.read_bytes()
            path.unlink()
            with self.subTest(missing=name), self.assertRaises(FileNotFoundError):
                self.validate()
            path.symlink_to(self.dmg if path != self.dmg else self.appcast)
            with self.subTest(link=name), self.assertRaises(ValueError):
                self.validate()
            path.unlink()
            path.write_bytes(content)
        path = self.root / 'toolchain-provenance.json'
        path.write_bytes(b' ' * (1024 ** 2 + 1))
        with self.assertRaises(ValueError):
            self.validate()


if __name__ == '__main__':
    unittest.main()
