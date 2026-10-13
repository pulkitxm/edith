import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


ROOT = Path(__file__).parent
CASES = module('synthetic_production_cases', ROOT / 'test-production-host-cohort.py')
INPUTS = module('synthetic_production_inputs', ROOT / 'hosted-public-release/production-static-inputs.py')


def synthetic_archive(directory, edit=lambda records: None):
    request = CASES.synthetic_request()
    package = request['packages']['previous']
    worker = package['workerContract']
    payload = 'keepAwake/'
    inner = 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex'
    attributes = {'EdithHostIdentifier': 'com.pulkit.edith', 'EdithExtensionID': 'keepAwake', 'EdithExtensionVersion': '1.0.0', 'EdithHostABI': 'edith-host-2', 'EdithExecutableProvenance': worker['frozenHostSHA256'], 'EdithCarrierExecutableProvenance': worker['carrierInputSHA256'], 'EdithHostCodeRequirement': request['hosts']['previous']['designatedRequirement'], 'EdithHostExecutablePath': INPUTS.COHORT.EXECUTABLE, 'EdithPayloadRelativePath': 'Contents/Resources/Payload'}
    records = {
        'package.json': json.dumps({key: package[key] for key in ['id', 'version', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies']}).encode(),
        worker['helperExecutable']: b'synthetic unexecuted native helper',
        worker['uiExecutable']: b'synthetic unexecuted managed UI',
        'ExtensionCarrier.app/Contents/MacOS/Edith': b'synthetic unexecuted tiny carrier',
        'ExtensionCarrier.app/Contents/Info.plist': plistlib.dumps({**attributes, 'CFBundleIdentifier': 'com.pulkit.edith.extension.keepAwake'}),
        inner + '/Contents/Info.plist': plistlib.dumps({**attributes, 'CFBundleIdentifier': 'com.pulkit.edith.extension.keepAwake.worker', 'EXAppExtensionAttributes': {'EXExtensionPointIdentifier': 'com.pulkit.edith.ExtensionUI'}}),
    }
    edit(records)
    for key, name in [('helperSHA256', worker['helperExecutable']), ('uiSHA256', worker['uiExecutable']), ('carrierSHA256', 'ExtensionCarrier.app/Contents/MacOS/Edith')]:
        worker[key] = hashlib.sha256(records.get(name, b'missing')).hexdigest()
    archive = directory / 'keepAwake.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as value:
        for name, data in records.items():
            info = zipfile.ZipInfo(payload + name)
            info.external_attr = 0o100600 << 16
            value.writestr(info, data)
    archive.chmod(0o600)
    package['archiveSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
    request['catalogs']['previous']['selectedArchiveSHA256'] = package['archiveSHA256']
    package['downloadBytes'] = archive.stat().st_size
    package['installedBytes'] = sum(map(len, records.values()))
    return {'request': request, 'generation': 'previous', 'directory': str(directory)}


class ProductionStaticInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='production-input-synthetic-')
        self.directory = Path(self.temporary.name).resolve()
        self.directory.chmod(0o700)
        self.addCleanup(self.temporary.cleanup)

    def verify(self, context):
        with patch.object(INPUTS, 'signing', return_value={'codeHash': 'a' * 40, 'requirement': 'synthetic unexecuted designated requirement'}):
            return INPUTS.package(context)

    def measured_context(self, directory, edit=lambda records: None):
        def current(records):
            manifest = json.loads(records['package.json'])
            manifest['version'] = '1.0.1'
            records['package.json'] = json.dumps(manifest).encode()
            for name in ['ExtensionCarrier.app/Contents/Info.plist', 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Info.plist']:
                info = plistlib.loads(records[name])
                info['EdithExtensionVersion'] = '1.0.1'
                records[name] = plistlib.dumps(info)
            edit(records)
        captured = synthetic_archive(directory, current)['request']['packages']['previous']
        template = CASES.synthetic_request()
        template['packages']['current'] = None
        template['catalogs']['current'] = None
        record = {key: captured[key] for key in ['id', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies', 'downloadBytes', 'installedBytes']}
        record.update(version='1.0.1', sourceFingerprint='4' * 64, sha256=captured['archiveSHA256'], downloadURL='https://github.com/pulkitxm/edith/releases/download/extensions%2FkeepAwake%2F1.0.1-' + '4' * 20 + '/keepAwake.zip')
        lineage = {'package': record, 'sourceCommit': template['source'], 'runID': 99, 'runAttempt': 1}
        return {'template': template, 'record': record, 'lineage': lineage, 'directory': str(directory)}

    def test_current_package_facts_are_measured_from_actual_zip_after_preparation(self):
        context = self.measured_context(self.directory)
        with patch.object(INPUTS, 'signing', return_value={'codeHash': 'a' * 40, 'requirement': 'synthetic unexecuted designated requirement'}) as signing:
            measured = INPUTS.measure_package(context)
        self.assertEqual(signing.call_count, 3)
        self.assertEqual(measured['archiveSHA256'], hashlib.sha256((self.directory / 'keepAwake.zip').read_bytes()).hexdigest())
        self.assertEqual(measured['source'], context['template']['source'])
        self.assertEqual(measured['run'], 99)
        self.assertEqual(measured['version'], '1.0.1')
        self.assertEqual(measured['workerContract']['helperSHA256'], hashlib.sha256(b'synthetic unexecuted native helper').hexdigest())
        self.assertIs(context['template']['packages']['current'], None)
        self.assertIs(context['template']['catalogs']['current'], None)
        INPUTS.COHORT.package(measured, '1.0.1')

    def test_measured_package_rejects_lineage_substitution_before_extraction(self):
        context = self.measured_context(self.directory)
        context['lineage']['sourceCommit'] = 'f' * 40
        with self.assertRaisesRegex(ValueError, 'lineage differs'):
            INPUTS.measure_package(context)
        self.assertFalse((self.directory / 'extracted').exists())

    def test_measured_package_cannot_claim_success_when_signature_or_worker_binding_fails(self):
        context = self.measured_context(self.directory)
        with patch.object(INPUTS, 'signing', side_effect=ValueError('synthetic signature failure')):
            with self.assertRaisesRegex(ValueError, 'signature failure'):
                INPUTS.measure_package(context)
        directory = self.directory / 'wrong-worker'
        directory.mkdir(mode=0o700)
        def edit(records):
            name = 'ExtensionCarrier.app/Contents/Info.plist'
            info = plistlib.loads(records[name])
            info['EdithHostExecutablePath'] = '/synthetic/foreign'
            records[name] = plistlib.dumps(info)
        context = self.measured_context(directory, edit)
        with patch.object(INPUTS, 'signing', return_value={'codeHash': 'a' * 40, 'requirement': 'synthetic unexecuted designated requirement'}):
            with self.assertRaisesRegex(ValueError, 'worker contract differs'):
                INPUTS.measure_package(context)

    def historical_records(self, stamp=False):
        expected = CASES.synthetic_request()['hosts']['previous']
        source, tag = expected['source'], expected['tag']
        target = 'f' * 40 if stamp else source
        records = {('cat-file', '-t', 'refs/tags/' + tag): b'commit\n', ('rev-parse', 'refs/tags/' + tag): target.encode() + b'\n'}
        before = {'CFBundleShortVersionString': '0.0.1', 'CFBundleVersion': '1', 'SyntheticUnchanged': 'retained'}
        after = {**before, 'CFBundleShortVersionString': expected['version'], 'CFBundleVersion': str(expected['build'])}
        old_cask = b'  version "0.0.1"\n  sha256 "' + b'1' * 64 + b'"\n'
        new_cask = b'  version "' + expected['version'].encode() + b'"\n  sha256 "' + expected['dmgSHA256'].encode() + b'"\n'
        for name in ('Resources/Info.plist', 'Resources/HelperInfo.plist'):
            records[('show', target + ':' + name)] = plistlib.dumps(after)
            if stamp:
                records[('show', source + ':' + name)] = plistlib.dumps(before)
        records[('show', target + ':Casks/edith.rb')] = new_cask
        if stamp:
            records[('show', source + ':Casks/edith.rb')] = old_cask
            records[('show', '-s', '--format=%P', target)] = source.encode() + b'\n'
            records[('show', '-s', '--format=%s', target)] = f'Release {tag} [skip ci]\n'.encode()
            records[('diff', '--name-only', source, target)] = b'Resources/Info.plist\nResources/HelperInfo.plist\nCasks/edith.rb\n'
        return expected, target, records

    def qualify_historical(self, expected, records):
        def output(arguments, timeout):
            self.assertEqual(timeout, 60)
            self.assertEqual(arguments[:3], ['git', '-C', str(self.directory)])
            return records[tuple(arguments[3:])]
        with patch.object(INPUTS.subprocess, 'check_output', side_effect=output):
            return INPUTS.historical_tag(self.directory, expected)

    def test_historical_direct_source_does_not_claim_latest_main_or_accept_annotated_tags(self):
        expected, target, records = self.historical_records()
        value = self.qualify_historical(expected, records)
        self.assertEqual(value['tagTargetCommit'], target)
        self.assertEqual(value['tagMode'], 'direct-source')
        self.assertIs(value['latestMainRequired'], False)
        records[('cat-file', '-t', 'refs/tags/' + expected['tag'])] = b'tag\n'
        with self.assertRaisesRegex(ValueError, 'lightweight tag'):
            self.qualify_historical(expected, records)

    def test_historical_stamp_preserves_exact_parent_and_all_nonversion_source_fields(self):
        expected, target, records = self.historical_records(stamp=True)
        self.assertEqual(self.qualify_historical(expected, records)['tagMode'], 'version-stamp-child')
        mutations = [
            {('show', '-s', '--format=%P', target): (expected['source'] + ' ' + 'b' * 40).encode()},
            {('show', target + ':Resources/Info.plist'): plistlib.dumps({'CFBundleShortVersionString': expected['version'], 'CFBundleVersion': str(expected['build']), 'SyntheticUnchanged': 'changed'})},
            {('diff', '--name-only', expected['source'], target): b'Sources/ChangedImplementation.swift\n'},
            {('show', target + ':Casks/edith.rb'): records[('show', target + ':Casks/edith.rb')] + b'changed-source\n'},
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.qualify_historical(expected, {**records, **mutation})

    def test_current_generation_cannot_reuse_historical_tag_without_exact_latest_main_binding(self):
        expected, target, records = self.historical_records()
        records[('rev-parse', 'refs/remotes/origin/main')] = b'f' * 40 + b'\n'
        def output(arguments, timeout):
            self.assertEqual(timeout, 60)
            self.assertEqual(arguments[:3], ['git', '-C', str(self.directory)])
            return records[tuple(arguments[3:])]
        with patch.object(INPUTS.subprocess, 'check_output', side_effect=output):
            self.assertEqual(INPUTS.release_tag(self.directory, expected, 'previous')['tagTargetCommit'], target)
            with self.assertRaisesRegex(ValueError, 'Public main must be the exact pinned release target'):
                INPUTS.release_tag(self.directory, expected, 'current')
            records[('rev-parse', 'refs/remotes/origin/main')] = target.encode() + b'\n'
            self.assertIs(INPUTS.release_tag(self.directory, expected, 'current')['mainMatchesTag'], True)

    def test_actual_zip_and_current_contained_helper_plists_are_read_without_native_execution(self):
        context = synthetic_archive(self.directory)
        value = self.verify(context)
        self.assertEqual(value['metrics']['installedBytes'], context['request']['packages']['previous']['installedBytes'])
        self.assertIn('/1.0.0/keepAwake/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/', value['managedUIRole']['executable'])
        self.assertIs(value['metrics']['codeExecuted'], False)

    def test_current_worker_must_bind_canonical_host_identity_requirement_version_and_frozen_inputs(self):
        fields = {'EdithHostExecutablePath': '/tmp/Edith.app/Contents/MacOS/Edith', 'EdithHostIdentifier': 'com.pulkit.edith.fixture', 'EdithExtensionID': 'foreign', 'EdithExtensionVersion': '9.9.9', 'EdithHostABI': 'edith-host-1', 'EdithExecutableProvenance': 'b' * 64, 'EdithCarrierExecutableProvenance': 'b' * 64, 'EdithHostCodeRequirement': 'foreign', 'EdithPayloadRelativePath': '../outside'}
        for index, (key, changed) in enumerate(fields.items()):
            directory = self.directory / str(index)
            directory.mkdir(mode=0o700)
            def edit(records):
                path = 'ExtensionCarrier.app/Contents/Info.plist'
                info = plistlib.loads(records[path])
                info[key] = changed
                records[path] = plistlib.dumps(info)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Current production worker contract differs"):
                self.verify(synthetic_archive(directory, edit))

    def test_wrong_inner_extension_point_and_identifier_reject_real_archive_metadata(self):
        path = 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Info.plist'
        for index, key in enumerate(['identifier', 'point']):
            directory = self.directory / str(index)
            directory.mkdir(mode=0o700)
            def edit(records):
                info = plistlib.loads(records[path])
                if key == 'identifier':
                    info['CFBundleIdentifier'] = 'foreign.worker'
                else:
                    info['EXAppExtensionAttributes']['EXExtensionPointIdentifier'] = 'foreign.ExtensionUI'
                records[path] = plistlib.dumps(info)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Wrong production UI identifier|Wrong extension point"):
                self.verify(synthetic_archive(directory, edit))

    def test_missing_current_helper_or_changed_download_size_cannot_reach_signature_approval(self):
        context = synthetic_archive(self.directory)
        context['request']['packages']['previous']['downloadBytes'] += 1
        with patch.object(INPUTS, 'signing') as signing, self.assertRaises(ValueError):
            INPUTS.package(context)
        signing.assert_not_called()

    def test_missing_current_contained_helper_rejects_before_any_native_signature_command(self):
        def edit(records):
            path = CASES.synthetic_request()['packages']['previous']['workerContract']['helperExecutable']
            del records[path]
        context = synthetic_archive(self.directory, edit)
        with patch.object(INPUTS, 'signing') as signing, self.assertRaises(FileNotFoundError):
            INPUTS.package(context)
        signing.assert_not_called()

    def test_owned_bounded_reads_reject_symlink_hardlink_permissive_and_fifo_without_hanging(self):
        path = self.directory / 'record'
        path.write_bytes(b'synthetic')
        path.chmod(0o600)
        self.assertEqual(INPUTS.bounded_owned_bytes(path, 9), b'synthetic')
        with self.assertRaises(ValueError):
            INPUTS.bounded_owned_bytes(path, 8)
        path.chmod(0o666)
        with self.assertRaises(ValueError):
            INPUTS.bounded_owned_bytes(path, 9)
        path.chmod(0o600)
        linked = self.directory / 'linked'
        os.link(path, linked)
        with self.assertRaises(ValueError):
            INPUTS.bounded_owned_bytes(path, 9)
        linked.unlink()
        linked.symlink_to(path)
        with self.assertRaises(ValueError):
            INPUTS.bounded_owned_bytes(linked, 9)
        fifo = self.directory / 'fifo'
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(ValueError):
            INPUTS.bounded_owned_bytes(fifo, 9)
        self.assertEqual(path.read_bytes(), b'synthetic')


if __name__ == '__main__':
    unittest.main()
