import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


report = module('extension-release-size-report')


class ReleaseAggregateTests(unittest.TestCase):
    def setUp(self):
        self.fixture_source = module('test-extension-host-size-report')
        self.fixture = self.fixture_source.HostSizeReportTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        index, definitions, fingerprints, source, host = self.fixture.final_fixture()
        for entry in index:
            path = self.fixture.packages / (entry['id'] + '.json')
            record = json.loads(path.read_text())
            record['downloadURL'] = 'https://github.com/pulkitxm/edith/releases/download/fixture/' + entry['id'] + '.zip'
            path.write_text(json.dumps(record))
        self.frozen = self.fixture_module().build_report(self.fixture.baseline, self.fixture.app,
            self.fixture.packages, definitions, index, fingerprints, host,
            expected_source_commit=source['sourceCommit'], source_state=source)
        self.shipping = self.fixture.root / 'shipping/Edith.app'
        shutil.copytree(self.fixture.app, self.shipping)
        self.exe = self.shipping / 'Contents/MacOS/Edith'
        self.exe.write_bytes(self.exe.read_bytes() + b'|signature:shipping')
        self.info = {**self.frozen['hostInfo'], 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123'}
        (self.shipping / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.index = self.shipping / 'Contents/Resources/index.json'
        self.index.parent.mkdir(parents=True)
        self.index.write_text(json.dumps(index))
        self.frozen['hostTreeInventory']['Contents/Resources/index.json'] = {
            'sha256': report.digest_file(self.index), 'mode': 0o644}
        self.assets = self.fixture.root / 'release-assets'
        self.assets.mkdir()
        for name in ['Edith.dmg', 'appcast.xml', 'catalog-1.json', 'pointer.json']:
            (self.assets / name).write_bytes(('synthetic ' + name).encode())
        self.metadata = {**host, 'sourceTreeDirty': True, 'hostExecutableSHA256': report.digest_file(self.exe),
                         'xcode': 'Xcode 27.0\nBuild version 27A100', 'sdk': '27.0', 'signature': 'synthetic certificate'}
        self.proof = {'schema': 1, 'sourceCommit': source['sourceCommit'], 'version': '1.2.3', 'build': '123',
            'sourceQualification': 'release-version-stamp-only', 'deepStrictSignatureVerified': True,
            'sparkleEd25519Verified': True, 'indexedExtensions': 39, 'extensionPayloadBytes': 0,
            'hostExecutableSHA256': report.digest_file(self.exe),
            'dmgSHA256': report.digest_file(self.assets / 'Edith.dmg'),
            'dmgBytes': (self.assets / 'Edith.dmg').stat().st_size,
            'appcastSHA256': report.digest_file(self.assets / 'appcast.xml'),
            'indexSHA256': report.digest_file(self.index),
            'installedBytes': sum(path.stat().st_size for path in report.TreeSnapshot(self.shipping).files)}
        self.toolchain = {'schema': 1, 'sourceCommit': source['sourceCommit'],
            'hostExecutableSHA256': report.digest_file(self.exe), 'xcode': self.metadata['xcode'],
            'sdk': self.metadata['sdk'], 'builderSignature': 'ad-hoc'}
        self.catalog = {'packages': copy.deepcopy(self.frozen['packages'])}
        for name, value in [('host-release-proof.json', self.proof), ('build-metadata.json', self.metadata),
                            ('toolchain-provenance.json', self.toolchain)]:
            (self.assets / name).write_text(json.dumps(value))
        self.evidence_fixture = module('test-release-evidence-sizes')
        self.evidence_assets, self.native_links = self.evidence_fixture.fixture(
            self.fixture.root, {row['id']: row for row in self.catalog['packages']})

    def fixture_module(self):
        return self.fixture_source.report

    def aggregate(self, **changes):
        arguments = {'frozen': self.frozen, 'shipping_app': self.shipping, 'shipping_metadata': self.metadata,
            'assets': self.assets, 'catalog_name': 'catalog-1.json', 'pointer_name': 'pointer.json',
            'catalog_key': 'synthetic-key', 'toolchain_receipt': self.toolchain, 'qualify': lambda *args: (self.proof, self.metadata),
            'catalog_verify': lambda *args: self.catalog, 'code_identity': self.fixture_module().executable_identity,
            'dmg_verify': lambda *args: True, 'evidence_assets': self.evidence_assets, 'native_links': self.native_links,
            'evidence_verify': self.evidence_fixture.verified}
        arguments.update(changes)
        return report.aggregate_release(**arguments)

    def test_raw_bytes_and_source_relationships_are_separate_and_copies_are_not_deducted(self):
        result = self.aggregate()
        self.assertEqual(result['frozenPackageHost']['hostExecutableSHA256'], self.frozen['hostExecutableSHA256'])
        self.assertNotEqual(result['signedShippingHost']['releaseProof']['hostExecutableSHA256'], self.frozen['hostExecutableSHA256'])
        self.assertTrue(result['signedShippingHost']['dmgContainedAppVerified'])
        self.assertEqual(result['signedShippingHost']['toolchainReceipt']['xcode'], self.metadata['xcode'])
        self.assertEqual(result['shippingAppPlusAll39LogicalBytes'], self.proof['installedBytes'] + sum(row['installedBytes'] for row in self.frozen['packages']))
        evidence = result['nativeEvidence']
        self.assertEqual(result['scopedReleaseAssetBytes'], sum(row['bytes'] for row in self.frozen['releaseArtifactInventory'])
            + sum(path.stat().st_size for path in self.assets.iterdir()) + evidence['totalEvidenceBytes'] + evidence['signedLinkBytes'])
        self.assertEqual(result['releaseAssetBytesByCategory']['originalNativeEvidenceArchives'], evidence['originalArchiveBytes'])
        self.assertEqual(result['releaseAssetBytesByCategory']['signedNativeEvidenceLinks'], evidence['signedLinkBytes'])
        self.assertEqual(result['artifactPublication'], 'not-verified')

    def test_old_or_dirty_frozen_host_and_stale_fingerprints_are_rejected(self):
        for field in ['sourceCommit', 'sourceTreeDirty']:
            frozen = copy.deepcopy(self.frozen)
            frozen['measurement']['hostBuild'][field] = 'b' * 40 if field == 'sourceCommit' else True
            with self.assertRaises(ValueError):
                self.aggregate(frozen=frozen)
        frozen = copy.deepcopy(self.frozen)
        frozen['packages'][0]['sourceFingerprint'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            self.aggregate(frozen=frozen)

    def test_unproven_dirty_shipping_state_and_proof_hash_mismatches_are_rejected(self):
        for change in [{'sourceQualification': 'dirty'}, {'sourceCommit': 'b' * 40}, {'dmgSHA256': 'b' * 64},
                       {'dmgBytes': 1}, {'appcastSHA256': 'b' * 64}, {'sparkleEd25519Verified': False},
                       {'deepStrictSignatureVerified': False}, {'installedBytes': 1}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.aggregate(qualify=lambda *args: ({**self.proof, **change}, self.metadata))
        with self.assertRaises(ValueError):
            self.aggregate(shipping_metadata={**self.metadata, 'sourceTreeDirty': False})

    def test_foreign_shipping_code_plist_resources_and_dmg_app_are_rejected(self):
        for name, data in [('Contents/MacOS/Edith', b'foreign code'), ('Contents/Resources/foreign', b'foreign')]:
            path = self.shipping / name
            original = path.read_bytes() if path.exists() else None
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                self.aggregate()
            path.unlink() if original is None else path.write_bytes(original)
        (self.shipping / 'Contents/Info.plist').write_bytes(plistlib.dumps({**self.info, 'extra': True}))
        with self.assertRaisesRegex(ValueError, 'plist'):
            self.aggregate()
        (self.shipping / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        with self.assertRaisesRegex(ValueError, 'DMG signed app binding'):
            self.aggregate(dmg_verify=lambda *args: False)

    def test_current_catalog_must_match_every_metadata_field_and_minimum_system_version(self):
        for field in ['sourceFingerprint', 'sha256', 'installedBytes', 'minimumSystemVersion', 'dependencies', 'hostABI', 'downloadURL']:
            catalog = copy.deepcopy(self.catalog)
            catalog['packages'][0][field] = 'foreign'
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.aggregate(catalog_verify=lambda *args: catalog)
        with self.assertRaises(ValueError):
            self.aggregate(catalog_verify=lambda *args: {'packages': self.catalog['packages'][:-1]})

    def test_unexpected_assets_bad_checksums_and_mutation_during_qualification_are_rejected(self):
        for name in ['orphan.zip', 'Edith.dmg.sha256']:
            path = self.assets / name
            path.write_bytes(b'foreign')
            with self.assertRaises(ValueError):
                self.aggregate()
            path.unlink()
        def qualify(*args):
            (self.assets / 'Edith.dmg').write_bytes(b'changed')
            return self.proof, self.metadata
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.aggregate(qualify=qualify)

    def test_maintained_catalog_signature_and_pointer_verification_with_synthetic_bytes(self):
        script = """import {createPrivateKey,createPublicKey,sign} from 'node:crypto';
const key = createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.alloc(32,7)]),format:'der',type:'pkcs8'});
const publicKey = createPublicKey(key).export({format:'jwk'}).x;
const payload = Buffer.from(process.argv[1]);
process.stdout.write(JSON.stringify({key:Buffer.from(publicKey,'base64url').toString('base64'),envelope:{payload:payload.toString('base64'),signature:sign(null,payload,key).toString('base64')}}));"""
        catalog = {'schemaVersion': 1, 'revision': 1, 'packages': self.catalog['packages']}
        value = json.loads(subprocess.run(['node', '--input-type=module', '-e', script, json.dumps(catalog)],
            check=True, capture_output=True, text=True).stdout)
        path = self.assets / 'catalog-1.json'
        path.write_text(json.dumps(value['envelope']))
        pointer = self.assets / 'pointer.json'
        pointer.write_text(json.dumps({'schemaVersion': 1, 'revision': 1, 'assetName': path.name,
            'bytes': path.stat().st_size, 'sha256': report.digest_file(path)}))
        verified = report.verify_catalog(path, pointer, value['key'])
        self.assertEqual(verified, catalog)
        pointer.write_text(pointer.read_text().replace('catalog-1.json', 'catalog-2.json'))
        with self.assertRaises(subprocess.CalledProcessError):
            report.verify_catalog(path, pointer, value['key'])

    def test_cli_rechecks_frozen_packages_after_independent_shipping_qualification(self):
        root = self.fixture.root
        source_index = root / 'Packages/EdithHost/Sources/EdithHostCore/Resources/index.json'
        source_index.parent.mkdir(parents=True)
        source_index.write_bytes(self.index.read_bytes())
        manifest = root / 'Extensions/manifest.json'
        manifest.parent.mkdir()
        manifest.write_text('[]')
        key_source = root / 'Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift'
        key_source.parent.mkdir(parents=True)
        key_source.write_text('base64Encoded: "c3ludGhldGlj"')
        documents = {'baseline': self.fixture.baseline, 'frozen-build': self.frozen['measurement']['hostBuild'],
                     'shipping-build': self.metadata, 'toolchain-receipt': self.toolchain}
        arguments = ['release-size-report']
        for name, data in documents.items():
            path = root / (name + '.json')
            path.write_text(json.dumps(data))
            arguments.extend(['--' + name, str(path)])
        for name, path in {'source-root': root, 'release-source-root': root, 'frozen-app': self.fixture.app,
                           'shipping-app': self.shipping, 'assets': self.assets, 'packages': self.fixture.packages,
                           'evidence-assets': self.evidence_assets, 'native-links': self.native_links,
                           'output': root / 'output.json'}.items():
            arguments.extend(['--' + name, str(path)])
        for name, value in {'source': 'a' * 40, 'tag': 'v1.2.3', 'version': '1.2.3', 'build': '123',
                            'catalog-name': 'catalog-1.json', 'pointer-name': 'pointer.json', 'notarization': 'skipped'}.items():
            arguments.extend(['--' + name, value])
        def aggregate(*args, **kwargs):
            (self.fixture.packages / 'sample0.zip').write_bytes(b'changed after frozen report')
            return {'signedShippingHost': {}}
        host = self.fixture_module()
        with patch.object(sys, 'argv', arguments), patch.object(report, 'load_report_module', return_value=host), patch.object(host, 'read_source_state', return_value={'sourceCommit': 'a' * 40, 'sourceTreeDirty': False}), patch.object(host, 'build_report', return_value=self.frozen), patch.object(report.subprocess, 'run', return_value=type('Result', (), {'stdout': json.dumps(self.frozen['sourceFingerprints'])})()), patch.object(report, 'aggregate_release', side_effect=aggregate):
            with self.assertRaisesRegex(ValueError, 'changed during measurement'):
                report.main()
        self.assertFalse((root / 'output.json').exists())

    def test_every_host_receipt_is_measured_and_bound_to_independent_qualification(self):
        for name in ['host-release-proof.json', 'build-metadata.json', 'toolchain-provenance.json']:
            path = self.assets / name
            original = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Missing final release asset'):
                self.aggregate()
            path.write_text('{}')
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'host receipt differs'):
                self.aggregate()
            path.write_bytes(original)

    def test_native_link_failures_and_evidence_mutations_fail_final_aggregation(self):
        link = next(self.native_links.iterdir())
        original = json.loads(link.read_text())
        link.write_text(json.dumps({**original, 'evidenceSHA256': 'b' * 64}))
        with self.assertRaisesRegex(ValueError, 'original lineage'):
            self.aggregate()
        link.write_text(json.dumps(original))
        def mutate(envelopes, links, key):
            result = self.evidence_fixture.verified(envelopes, links, key)
            (envelopes[0].parent / 'extension-plan-1.zip').write_bytes(b'changed original evidence')
            return result
        with self.assertRaisesRegex(ValueError, 'bytes or hash'):
            self.aggregate(evidence_verify=mutate)

    def test_toolchain_receipt_is_closed_bounded_and_bound_to_final_executable(self):
        for change in [{'schema': True}, {'sourceCommit': 'b' * 40}, {'hostExecutableSHA256': 'b' * 64},
                       {'xcode': 'private path'}, {'sdk': '27.0' * 100}, {'builderSignature': 'Developer ID'},
                       {'personalName': 'synthetic'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.aggregate(toolchain_receipt={**self.toolchain, **change})

    def test_maintained_release_source_qualification_is_called_without_relaxing_dirty_state(self):
        with patch.object(report.host_release_proof, 'qualify_source', return_value={'workflowSourceCommit': 'a' * 40}) as qualification, patch.object(report.host_release_proof, 'pinned_sources', return_value=({}, b'index', True)) as pinned, patch.object(report.host_release_proof, 'collect_proof', return_value=({}, self.metadata)) as collect:
            proof, metadata = report.qualify_release(self.shipping, self.assets / 'Edith.dmg', self.assets / 'appcast.xml', self.metadata, self.fixture.root, 'a' * 40, 'v1.2.3', '1.2.3', '123', 'skipped')
            self.assertEqual(proof['sourceQualification'], 'release-version-stamp-only')
            qualification.assert_called_once()
            pinned.assert_called_once()
            collect.assert_called_once()
            with patch.object(report, 'inspect_layout', return_value={}) as layout:
                collect.call_args.kwargs['layout'](self.shipping, release=True, launcher_required=True)
                layout.assert_called_once_with(self.shipping, release=True, launcher_required=False)
            with self.assertRaisesRegex(ValueError, 'maintained source qualification'):
                report.qualify_release(self.shipping, self.assets / 'Edith.dmg', self.assets / 'appcast.xml', {**self.metadata, 'sourceTreeDirty': False}, self.fixture.root, 'a' * 40, 'v1.2.3', '1.2.3', '123', 'skipped')


if __name__ == '__main__':
    unittest.main()
