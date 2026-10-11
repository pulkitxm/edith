import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from release_evidence_sizes import measure_native_evidence
from size_report_filesystem import digest_file


def fixture(root, records, source='a' * 40, run=100, attempt=1, directories=None, composition=True):
    directory, links = directories or (root / 'evidence-assets', root / 'native-links')
    release = directory / source / f'{run}-{attempt}'
    release.mkdir(parents=True)
    links.mkdir(exist_ok=True)
    artifacts = []
    for number, name in enumerate(['extension-plan', 'frozen-extension-host'] + ['extension-' + identifier for identifier in records], 1):
        archive = release / f'{name}-{number}.zip'
        archive.write_bytes(b'original synthetic archive bytes')
        artifacts.append({'name': name, 'artifactID': number, 'artifactBytes': archive.stat().st_size,
                          'artifactSHA256': digest_file(archive), 'assetName': archive.name})
    payload = {'sourceCommit': source, 'runID': run, 'runAttempt': attempt, 'plannedIDs': sorted(records),
               'fingerprints': {identifier: record['sourceFingerprint'] for identifier, record in records.items()},
               'artifacts': artifacts}
    envelope = release / 'native-evidence.json'
    envelope.write_text(json.dumps(payload))
    for identifier, record in records.items():
        (links / (identifier + '.native-evidence.json')).write_text(json.dumps({
            'package': record, 'sourceCommit': source, 'runID': run, 'runAttempt': attempt,
            'evidenceTag': f'extension-evidence/{source}/{run}-{attempt}',
            'evidenceSHA256': digest_file(envelope), 'evidenceBytes': envelope.stat().st_size}))
    if composition:
        compose(release, links, records, source, run, attempt)
    return directory, links


def compose(release, links, records, source='a' * 40, run=100, attempt=1):
    rows = []
    for identifier in sorted(records):
        path = links / (identifier + '.native-evidence.json')
        lineage = json.loads(path.read_text())
        rows.append({field: lineage[field] for field in
                     ['package', 'sourceCommit', 'runID', 'runAttempt', 'evidenceSHA256', 'evidenceBytes']})
        rows[-1].update({'lineageSHA256': digest_file(path), 'lineageBytes': path.stat().st_size})
    (release / 'publication-composition.json').write_text(json.dumps({
        'sourceCommit': source, 'publicationRunID': run, 'publicationAttempt': attempt, 'packages': rows}))


def verified(releases, links, key, current):
    evidence, compositions, inventories = [], [], []
    for release in releases:
        payload = json.loads(Path(release['path']).read_text())
        composition = json.loads(Path(release['compositionPath']).read_text()) if release['compositionPath'] else None
        assets = [{'name': 'native-evidence.json', **release['envelope']}]
        for row in payload['artifacts']:
            assets.append({'name': row['assetName'], 'bytes': row['artifactBytes'], 'sha256': row['artifactSHA256']})
        if composition is not None:
            assets.append({'name': 'publication-composition.json', **release['composition']})
        if {row['name'] for row in assets} != {row['name'] for row in release['assets']}:
            raise ValueError('Missing original or unknown archive inventory')
        for expected in assets:
            actual = next(row for row in release['assets'] if row['name'] == expected['name'])
            if actual['size'] != expected['bytes'] or actual['digest'] != 'sha256:' + expected['sha256']:
                raise ValueError('Original native evidence archive bytes or hash differs')
        archive_bytes = sum(row['artifactBytes'] for row in payload['artifacts'])
        composition_bytes = release['composition']['bytes'] if composition else 0
        inventories.append({'assets': assets, 'envelopeBytes': release['envelope']['bytes'],
            'envelopeSHA256': release['envelope']['sha256'], 'originalArchiveBytes': archive_bytes,
            'compositionBytes': composition_bytes,
            'totalEvidenceBytes': archive_bytes + release['envelope']['bytes'] + composition_bytes})
        evidence.append(payload)
        compositions.append(composition)
    return {'evidence': evidence, 'lineages': [json.loads(Path(row['path']).read_text()) for row in links],
            'compositions': compositions, 'inventories': inventories}


class EvidenceSizeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.records = {identifier: {'id': identifier, 'sourceFingerprint': 'f' * 64, 'sha256': 'c' * 64}
                        for identifier in ['first', 'second']}
        self.directory, self.links = fixture(self.root, self.records)
        self.release = self.directory / ('a' * 40) / '100-1'

    def measure(self, verify=verified, current=None):
        return measure_native_evidence(self.directory, self.links, self.records, 'synthetic-key',
            current or {'source': 'a' * 40, 'runID': 100, 'attempt': 1}, verify)

    def test_shared_release_is_counted_once_and_duplicate_archive_bytes_are_kept(self):
        result = self.measure()
        self.assertEqual(len(result['releases']), 1)
        self.assertEqual(result['originalArchiveBytes'], 4 * len(b'original synthetic archive bytes'))
        self.assertEqual(result['totalEvidenceBytes'], sum(path.stat().st_size for path in self.release.iterdir()))
        self.assertEqual(result['signedLinkBytes'], sum(path.stat().st_size for path in self.links.iterdir()))
        self.assertEqual(len(result['releases'][0]['closedAssetInventory']), 6)

    def test_retained_original_source_runs_are_bound_without_relabeling(self):
        shutil.rmtree(self.directory)
        shutil.rmtree(self.links)
        fixture(self.root, {'first': self.records['first']}, source='b' * 40, composition=False, directories=(self.directory, self.links))
        fixture(self.root, {'second': self.records['second']}, run=200, attempt=2, composition=False, directories=(self.directory, self.links))
        saved = {path: path.read_bytes() for path in self.links.iterdir()}
        fixture(self.root, self.records, source='c' * 40, run=300,
                composition=False, directories=(self.directory, self.links))
        for path, data in saved.items():
            path.write_bytes(data)
        compose(self.directory / ('c' * 40) / '300-1', self.links, self.records, 'c' * 40, 300)
        result = self.measure(current={'source': 'c' * 40, 'runID': 300, 'attempt': 1})
        self.assertEqual(len(result['releases']), 3)
        self.assertEqual({row['sourceCommit'] for row in result['releases']}, {'a' * 40, 'b' * 40, 'c' * 40})
        self.assertEqual(result['originalArchiveBytes'], 10 * len(b'original synthetic archive bytes'))

    def test_missing_changed_archives_and_foreign_inventory_are_rejected(self):
        archive = self.release / 'extension-plan-1.zip'
        archive.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing original'):
            self.measure()
        archive.write_bytes(b'original synthetic archive bytes')
        archive.write_bytes(b'changed synthetic archive bytes!')
        with self.assertRaisesRegex(ValueError, 'bytes or hash'):
            self.measure()
        archive.write_bytes(b'original synthetic archive bytes')
        orphan = self.release / 'orphan-99.zip'
        orphan.write_bytes(b'orphan')
        with self.assertRaisesRegex(ValueError, 'archive inventory'):
            self.measure()
        orphan.unlink()
        (self.directory / ('b' * 40)).mkdir()
        with self.assertRaisesRegex(ValueError, 'release inventory'):
            self.measure()

    def test_lineages_must_bind_exact_package_envelope_fingerprint_and_run(self):
        path = self.links / 'first.native-evidence.json'
        original = json.loads(path.read_text())
        for change in [{'package': {**self.records['first'], 'sha256': 'd' * 64}},
                       {'sourceCommit': 'b' * 40}, {'runID': 200}, {'runAttempt': 2},
                       {'evidenceTag': 'extension-evidence/' + 'b' * 40 + '/100-1'},
                       {'evidenceBytes': 1}, {'evidenceSHA256': 'e' * 64}]:
            with self.subTest(change=change):
                path.write_text(json.dumps({**original, **change}))
                with self.assertRaisesRegex(ValueError, 'original lineage'):
                    self.measure()
        path.write_text(json.dumps(original))
        def mismatch(releases, links, key, current):
            result = verified(releases, links, key, current)
            result['evidence'][0]['fingerprints']['first'] = 'e' * 64
            return result
        with self.assertRaisesRegex(ValueError, 'current publication fingerprints'):
            self.measure(mismatch)

    def test_missing_foreign_symlink_and_oversized_links_are_rejected(self):
        path = self.links / 'first.native-evidence.json'
        original = path.read_bytes()
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing native evidence link'):
            self.measure()
        path.write_bytes(original)
        orphan = self.links / 'foreign.native-evidence.json'
        orphan.write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError, 'link inventory'):
            self.measure()
        orphan.unlink()
        path.write_bytes(b'x' * (16 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, 'link inventory'):
            self.measure()
        path.unlink()
        path.symlink_to(self.links / 'second.native-evidence.json')
        with self.assertRaisesRegex(ValueError, 'link inventory'):
            self.measure()

    def test_unreferenced_evidence_release_and_misnamed_identity_are_rejected(self):
        path = self.links / 'first.native-evidence.json'
        original = path.read_bytes()
        fixture(self.root, {'first': self.records['first']}, run=200, directories=(self.directory, self.links))
        path.write_bytes(original)
        with self.assertRaisesRegex(ValueError, 'Unreferenced'):
            self.measure()
        shutil.rmtree(self.directory / ('a' * 40) / '200-1')
        self.release.rename(self.release.with_name('101-1'))
        with self.assertRaisesRegex(ValueError, 'current publication evidence release'):
            self.measure()

    def test_verifier_failures_and_mutating_inputs_are_not_suppressed(self):
        def fail(*args):
            raise ValueError('synthetic invalid signature')
        with self.assertRaisesRegex(ValueError, 'invalid signature'):
            self.measure(fail)
        def mutate(releases, links, key, current):
            result = verified(releases, links, key, current)
            Path(links[0]['path']).write_bytes(b'changed during verification')
            return result
        with self.assertRaisesRegex(ValueError, 'changed during measurement'):
            self.measure(mutate)


class SignedCompositionSizeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not Path('scripts/hosted-public-release/evidence.mjs').is_file():
            raise unittest.SkipTest('Maintained public evidence module requires owner integration')

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.generate()

    def generate(self, mode='retained'):
        for path in self.root.iterdir():
            shutil.rmtree(path)
        self.value = json.loads(subprocess.run(['node', 'scripts/test-release-evidence-fixture.mjs', str(self.root), mode],
            check=True, capture_output=True, text=True).stdout)
        self.directory = self.root / 'evidence-assets'
        self.links = self.root / 'native-links'
        self.current_release = self.directory / ('b' * 40) / '300-2'
        self.composition = self.current_release / 'publication-composition.json'
        self.original_release = self.directory / ('a' * 40) / '100-1'

    def measure(self, **changes):
        arguments = {'directory': self.directory, 'links': self.links, 'records': self.value['records'],
                     'key': self.value['key'], 'current': self.value['current']}
        arguments.update(changes)
        return measure_native_evidence(**arguments)

    def resign(self, path, payload):
        path.write_text(json.dumps(payload))
        subprocess.run(['node', 'scripts/test-release-evidence-fixture.mjs', str(path), 'resign'],
                       check=True, capture_output=True, text=True)

    def payload(self, path):
        import base64
        return json.loads(base64.b64decode(json.loads(path.read_text())['payload']))

    def test_all39_retained_links_include_distinct_current_release_and_every_byte(self):
        result = self.measure()
        self.assertEqual(len(result['releases']), 2)
        self.assertEqual(len(result['links']), 39)
        self.assertEqual(result['currentPublicationTag'], 'extension-evidence/' + 'b' * 40 + '/300-2')
        self.assertEqual({row['lineage']['sourceCommit'] for row in result['links']}, {'a' * 40})
        self.assertEqual(result['originalArchiveBytes'], 44 * len(b'original synthetic archive bytes'))
        self.assertEqual(result['compositionBytes'], self.composition.stat().st_size)
        self.assertEqual(result['totalEvidenceBytes'], sum(path.stat().st_size for path in self.directory.rglob('*') if path.is_file()))
        self.assertEqual(result['signedLinkBytes'], sum(path.stat().st_size for path in self.links.iterdir()))
        self.assertEqual(result['totalEvidenceBytes'], result['envelopeBytes'] + result['compositionBytes'] + result['originalArchiveBytes'])

    def test_current_original_release_is_counted_once(self):
        self.generate('current')
        result = self.measure()
        self.assertEqual(len(result['releases']), 1)
        self.assertEqual(result['originalArchiveBytes'], 41 * len(b'original synthetic archive bytes'))
        self.assertEqual(result['totalEvidenceBytes'], sum(path.stat().st_size for path in self.current_release.iterdir()))

    def test_actual_historical_and_current_composition_bytes_are_both_counted(self):
        self.generate('historical-composition')
        result = self.measure()
        self.assertEqual(result['compositionBytes'], sum(path.stat().st_size for path in self.directory.rglob('publication-composition.json')))
        self.assertEqual(result['totalEvidenceBytes'], sum(path.stat().st_size for path in self.directory.rglob('*') if path.is_file()))

    def test_composition_and_original_signature_tampering_are_rejected(self):
        for path in [self.composition, self.original_release / 'native-evidence.json', self.links / 'first.native-evidence.json']:
            original = path.read_bytes()
            value = json.loads(original)
            value['signature'] = ('A' if value['signature'][0] != 'A' else 'B') + value['signature'][1:]
            path.write_text(json.dumps(value))
            with self.subTest(path=path.name), self.assertRaises(subprocess.CalledProcessError):
                self.measure()
            path.write_bytes(original)

    def test_signed_wrong_current_source_run_attempt_and_catalog_are_rejected(self):
        original = self.composition.read_bytes()
        for field, value in [('sourceCommit', 'a' * 40), ('publicationRunID', 100), ('publicationAttempt', 1)]:
            payload = self.payload(self.composition)
            payload[field] = value
            self.resign(self.composition, payload)
            with self.subTest(field=field), self.assertRaises(subprocess.CalledProcessError):
                self.measure()
            self.composition.write_bytes(original)
        payload = self.payload(self.composition)
        payload['packages'][0]['package']['sha256'] = 'd' * 64
        self.resign(self.composition, payload)
        with self.assertRaises(subprocess.CalledProcessError):
            self.measure()

    def test_signed_wrong_row_link_and_original_envelope_bindings_are_rejected(self):
        original = self.composition.read_bytes()
        for field, value in [('lineageSHA256', 'd' * 64), ('lineageBytes', 1), ('sourceCommit', 'b' * 40),
                             ('runID', 300), ('runAttempt', 2), ('evidenceSHA256', 'd' * 64), ('evidenceBytes', 1)]:
            payload = self.payload(self.composition)
            payload['packages'][0][field] = value
            self.resign(self.composition, payload)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'composition differs'):
                self.measure()
            self.composition.write_bytes(original)
        path = self.links / 'first.native-evidence.json'
        payload = self.payload(path)
        payload['evidenceSHA256'] = 'd' * 64
        self.resign(path, payload)
        with self.assertRaisesRegex(ValueError, 'original lineage'):
            self.measure()

    def test_missing_unknown_duplicate_and_changed_assets_are_rejected_by_owner(self):
        archive = self.current_release / 'extension-plan-1.zip'
        original = archive.read_bytes()
        archive.unlink()
        with self.assertRaises(subprocess.CalledProcessError):
            self.measure()
        archive.write_bytes(original + b'changed')
        with self.assertRaises(subprocess.CalledProcessError):
            self.measure()
        archive.write_bytes(original)
        for name in ['unknown.json', 'extension-plan-999.zip', 'native-evidence-copy.json']:
            orphan = self.current_release / name
            orphan.write_bytes(original)
            with self.subTest(name=name), self.assertRaises(subprocess.CalledProcessError):
                self.measure()
            orphan.unlink()
        payload = self.payload(self.composition)
        payload['packages'][1] = payload['packages'][0]
        self.resign(self.composition, payload)
        with self.assertRaises(subprocess.CalledProcessError):
            self.measure()

    def test_missing_current_release_composition_or_link_is_rejected(self):
        original = self.composition.read_bytes()
        self.composition.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing current publication composition'):
            self.measure()
        self.composition.write_bytes(original)
        shutil.rmtree(self.current_release)
        with self.assertRaisesRegex(ValueError, 'Missing current publication evidence release'):
            self.measure()
        self.generate()
        (self.links / 'first.native-evidence.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing native evidence link'):
            self.measure()

    def test_current_envelope_fingerprints_must_match_current_records(self):
        path = self.current_release / 'native-evidence.json'
        payload = self.payload(path)
        payload['fingerprints']['second'] = 'e' * 64
        self.resign(path, payload)
        with self.assertRaisesRegex(ValueError, 'current publication fingerprints'):
            self.measure()


if __name__ == '__main__':
    unittest.main()
