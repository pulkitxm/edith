import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


ROOT = Path(__file__).resolve().parents[1]
INPUTS = module('measured_host', ROOT / 'scripts/hosted-public-release/production-static-inputs.py')
CASES = module('measured_cases', ROOT / 'scripts/test-production-host-cohort.py')


class MeasureHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.directory = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        template = CASES.synthetic_request()
        template['schema'] = 2
        template['packages']['current'] = None
        template['catalogs']['current'] = None
        template['hosts']['current'] = {'kind': 'pending-public-host', 'source': template['source'], 'run': 12, 'runAttempt': 1, 'tag': 'v0.0.402', 'version': '0.0.402', 'build': 2}
        self.context = {'template': template, 'generation': 'current', 'directory': str(self.directory), 'releaseChannel': {'id': 123, 'draft': False, 'prerelease': True, 'tag_name': 'v0.0.402', 'target_commitish': 'f' * 40}}
        self.proof = {'sourceCommit': template['source'], 'workflowSourceCommit': template['source'], 'version': '0.0.402', 'build': '2', 'dmgURL': 'https://github.com/pulkitxm/edith/releases/download/v0.0.402/Edith.dmg', 'dmgSHA256': '2' * 64, 'dmgBytes': 100, 'appcastSHA256': '3' * 64, 'hostExecutableSHA256': '4' * 64, 'installedBytes': 200, 'extensionPayloadBytes': 0, 'teamIdentifier': 'ABCDEFGHIJ', 'certificateCategory': 'Apple Development', 'notarization': 'skipped', 'verifiedDesignatedRequirement': template['hosts']['previous']['designatedRequirement']}
        self.proof_path = self.directory / 'host-release-proof.json'
        self.write_proof()
        metadata = self.directory / 'build-metadata.json'
        metadata.write_text(json.dumps({'architecture': 'arm64'}))
        metadata.chmod(0o600)
        self.qualification = {'implementation': {'normalizedUnsignedSHA256': '5' * 64}, 'deepStrictSignatureVerified': True, 'publicStaticProof': {'sparkleEd25519Verified': True}, 'tagIdentity': {'tagTargetCommit': 'f' * 40}}
        for name in ['Edith.dmg', 'appcast.xml', 'toolchain-provenance.json']:
            path = self.directory / name
            path.write_bytes(('synthetic unexecuted ' + name).encode())
            path.chmod(0o600)
        pending = template['hosts']['current']
        jobs = [{'id': index, 'run_id': pending['run'], 'run_attempt': pending['runAttempt'], 'head_sha': pending['source'], 'name': name, 'status': 'completed', 'conclusion': 'success'} for index, name in enumerate(['Build DMG', 'Publish release'], 1)]
        self.context['publication'] = {'run': {'id': pending['run'], 'run_attempt': pending['runAttempt'], 'head_sha': pending['source'], 'head_branch': 'main', 'event': 'workflow_dispatch', 'path': '.github/workflows/ci.yml', 'repository': {'id': 1289153439, 'full_name': 'pulkitxm/edith'}, 'actor': {'id': 65671483}, 'status': 'completed', 'conclusion': 'success'}, 'jobs': {'total_count': len(jobs), 'jobs': jobs}, 'release': {**self.context['releaseChannel'], 'assets': []}, 'tag': {'ref': 'refs/tags/' + pending['tag'], 'object': {'type': 'commit', 'sha': 'f' * 40}}}
        self.refresh_assets()

    def write_proof(self):
        self.proof_path.write_text(json.dumps(self.proof))
        self.proof_path.chmod(0o600)
        if 'publication' in self.context:
            self.refresh_assets()

    def refresh_assets(self):
        self.context['publication']['release']['assets'] = [{'id': index, 'name': path.name, 'size': path.stat().st_size, 'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(), 'state': 'uploaded', 'browser_download_url': 'https://github.com/pulkitxm/edith/releases/download/v0.0.402/' + path.name} for index, path in enumerate(sorted(self.directory.iterdir()), 100) if path.name in ['Edith.dmg', 'appcast.xml', 'host-release-proof.json', 'build-metadata.json', 'toolchain-provenance.json']]

    def test_measured_fields_come_from_owned_receipt_and_actual_inspector_result(self):
        with patch.object(INPUTS, 'inspect_host', return_value=self.qualification) as inspect:
            result = INPUTS.measure_host(self.context)
        self.assertEqual(result['host']['proofSHA256'], hashlib.sha256(self.proof_path.read_bytes()).hexdigest())
        self.assertEqual(result['host']['normalizedUnsignedSHA256'], '5' * 64)
        self.assertEqual(result['host']['hostExecutableSHA256'], self.proof['hostExecutableSHA256'])
        self.assertEqual(result['host']['run'], 12)
        self.assertEqual(result['host']['source'], self.context['template']['source'])
        self.assertIsNone(inspect.call_args.args[-1])
        INPUTS.COHORT.host(result['host'])
        self.assertEqual(result['qualification'], self.qualification)

    def test_changed_source_version_build_or_signer_rejects_before_inspection(self):
        for name, value in [('sourceCommit', 'b' * 40), ('workflowSourceCommit', 'b' * 40), ('version', '0.0.403'), ('build', '3'), ('teamIdentifier', 'KLMNOPQRST')]:
            original = self.proof[name]
            self.proof[name] = value
            self.write_proof()
            with self.subTest(name=name), patch.object(INPUTS, 'inspect_host') as inspect, self.assertRaises(ValueError):
                INPUTS.measure_host(self.context)
            inspect.assert_not_called()
            self.proof[name] = original

    def test_pending_current_never_passes_strict_host_constructor(self):
        with self.assertRaisesRegex(ValueError, 'Pending current'):
            INPUTS.host({'request': self.context['template'], 'generation': 'current', 'directory': str(self.directory), 'releaseChannel': self.context['releaseChannel']})
        for change in [{'generation': 'previous'}, {'publicationVerified': True}]:
            with self.assertRaises(ValueError):
                INPUTS.measure_host({**self.context, **change})
        context = copy.deepcopy(self.context)
        context['template']['hosts']['current']['run'] = None
        context['template']['hosts']['current']['runAttempt'] = None
        with self.assertRaises(ValueError):
            INPUTS.measure_host(context)

    def test_native_signature_or_normalization_failure_never_returns_complete_host(self):
        for error in [ValueError('Synthetic signature failure'), ValueError('Synthetic normalization failure')]:
            with patch.object(INPUTS, 'inspect_host', side_effect=error), self.assertRaises(ValueError):
                INPUTS.measure_host(self.context)
        same = {**self.qualification, 'implementation': {'normalizedUnsignedSHA256': self.context['template']['hosts']['previous']['normalizedUnsignedSHA256']}}
        with patch.object(INPUTS, 'inspect_host', return_value=same), self.assertRaisesRegex(ValueError, 'did not change'):
            INPUTS.measure_host(self.context)

    def test_mid_inspection_receipt_mutation_fails_final_revalidation(self):
        def inspect(*args):
            self.proof['installedBytes'] += 1
            self.write_proof()
            return self.qualification
        with patch.object(INPUTS, 'inspect_host', side_effect=inspect), self.assertRaisesRegex(ValueError, 'asset changed|receipt changed'):
            INPUTS.measure_host(self.context)


    def test_failed_or_replayed_run_job_and_actor_facts_reject_before_native_inspection(self):
        for section, field, value in [('run', 'status', 'in_progress'), ('run', 'run_attempt', 2), ('run', 'head_sha', 'b' * 40), ('run', 'conclusion', 'failure'), ('job', 'run_attempt', 2), ('job', 'head_sha', 'b' * 40), ('job', 'conclusion', 'skipped')]:
            context = copy.deepcopy(self.context)
            target = context['publication']['run'] if section == 'run' else context['publication']['jobs']['jobs'][0]
            target[field] = value
            with self.subTest(section=section, field=field), patch.object(INPUTS, 'inspect_host') as inspect, self.assertRaises(ValueError):
                INPUTS.measure_host(context)
            inspect.assert_not_called()
        context = copy.deepcopy(self.context)
        context['publication']['run']['actor']['id'] = 123
        with patch.object(INPUTS, 'inspect_host') as inspect, self.assertRaises(ValueError):
            INPUTS.measure_host(context)
        inspect.assert_not_called()

    def test_public_assets_must_be_actual_complete_unique_and_match_downloaded_bytes(self):
        for mutation in ['digest', 'size', 'url', 'duplicate', 'draft', 'tag']:
            context = copy.deepcopy(self.context)
            asset = context['publication']['release']['assets'][0]
            if mutation == 'digest':
                asset['digest'] = 'sha256:' + 'f' * 64
            elif mutation == 'size':
                asset['size'] += 1
            elif mutation == 'url':
                asset['browser_download_url'] = 'https://example.invalid/synthetic'
            elif mutation == 'duplicate':
                context['publication']['release']['assets'][0] = context['publication']['release']['assets'][1]
            elif mutation == 'draft':
                context['publication']['release']['draft'] = True
            else:
                context['publication']['tag']['object']['type'] = 'tag'
            with self.subTest(mutation=mutation), patch.object(INPUTS, 'inspect_host') as inspect, self.assertRaises(ValueError):
                INPUTS.measure_host(context)
            inspect.assert_not_called()

    def test_success_booleans_cannot_replace_native_results_or_tag_binding(self):
        for qualification in [{**self.qualification, 'deepStrictSignatureVerified': False}, {**self.qualification, 'publicStaticProof': {'sparkleEd25519Verified': False}}, {**self.qualification, 'tagIdentity': {'tagTargetCommit': 'e' * 40}}]:
            with patch.object(INPUTS, 'inspect_host', return_value=qualification), self.assertRaises(ValueError):
                INPUTS.measure_host(self.context)
        context = copy.deepcopy(self.context)
        context['publication']['publicationVerified'] = True
        with patch.object(INPUTS, 'inspect_host') as inspect, self.assertRaises(ValueError):
            INPUTS.measure_host(context)
        inspect.assert_not_called()


if __name__ == '__main__':
    unittest.main()
