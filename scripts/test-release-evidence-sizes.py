import json
from pathlib import Path
import shutil
import tempfile
import unittest

from release_evidence_sizes import measure_native_evidence
from size_report_filesystem import digest_file


def fixture(root, records, source='a' * 40, run=100, attempt=1, directories=None):
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
    return directory, links


def verified(envelopes, links, key):
    return {'evidence': [json.loads(path.read_text()) for path in envelopes],
            'lineages': [json.loads(Path(row['path']).read_text()) for row in links]}


class EvidenceSizeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.records = {identifier: {'id': identifier, 'sourceFingerprint': 'f' * 64, 'sha256': 'c' * 64}
                        for identifier in ['first', 'second']}
        self.directory, self.links = fixture(self.root, self.records)
        self.release = self.directory / ('a' * 40) / '100-1'

    def measure(self, verify=verified):
        return measure_native_evidence(self.directory, self.links, self.records, 'synthetic-key', verify)

    def test_shared_release_is_counted_once_and_duplicate_archive_bytes_are_kept(self):
        result = self.measure()
        self.assertEqual(len(result['releases']), 1)
        self.assertEqual(result['originalArchiveBytes'], 4 * len(b'original synthetic archive bytes'))
        self.assertEqual(result['totalEvidenceBytes'], sum(path.stat().st_size for path in self.release.iterdir()))
        self.assertEqual(result['signedLinkBytes'], sum(path.stat().st_size for path in self.links.iterdir()))
        self.assertEqual(len(result['releases'][0]['closedAssetInventory']), 5)

    def test_retained_original_source_runs_are_bound_without_relabeling(self):
        shutil.rmtree(self.directory)
        shutil.rmtree(self.links)
        fixture(self.root, {'first': self.records['first']}, source='b' * 40, directories=(self.directory, self.links))
        fixture(self.root, {'second': self.records['second']}, run=200, attempt=2, directories=(self.directory, self.links))
        result = self.measure()
        self.assertEqual(len(result['releases']), 2)
        self.assertEqual({row['sourceCommit'] for row in result['releases']}, {'a' * 40, 'b' * 40})
        self.assertEqual(result['originalArchiveBytes'], 6 * len(b'original synthetic archive bytes'))

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
        with self.assertRaisesRegex(ValueError, 'archive inventory'):
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
        def mismatch(envelopes, links, key):
            result = verified(envelopes, links, key)
            result['evidence'][0]['fingerprints']['first'] = 'e' * 64
            return result
        with self.assertRaisesRegex(ValueError, 'original lineage'):
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
        with self.assertRaisesRegex(ValueError, 'release identity'):
            self.measure()

    def test_verifier_failures_and_mutating_inputs_are_not_suppressed(self):
        def fail(*args):
            raise ValueError('synthetic invalid signature')
        with self.assertRaisesRegex(ValueError, 'invalid signature'):
            self.measure(fail)
        def mutate(envelopes, links, key):
            result = verified(envelopes, links, key)
            Path(links[0]['path']).write_bytes(b'changed during verification')
            return result
        with self.assertRaisesRegex(ValueError, 'changed during measurement'):
            self.measure(mutate)


if __name__ == '__main__':
    unittest.main()
