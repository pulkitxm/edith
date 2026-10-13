import hashlib
import os
import importlib.util
import copy
import json
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('synthetic_sparkle_inputs', Path(__file__).parent / 'hosted-public-release/production-sparkle-inputs.py')
INPUTS = importlib.util.module_from_spec(spec)
spec.loader.exec_module(INPUTS)


class ProductionSparkleInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sparkle-input-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.bundle = self.root / 'Edith.app'
        self.host = self.bundle / 'Contents/MacOS/Edith'
        self.write(self.host, b'synthetic unexecuted host')
        self.expected = {'hostExecutableSHA256': hashlib.sha256(self.host.read_bytes()).hexdigest(), 'teamIdentifier': 'ABCDEFGHIJ', 'designatedRequirement': 'synthetic fixed host requirement'}
        for relative in INPUTS.EXECUTABLES.values():
            self.write(self.bundle / INPUTS.PREFIX / relative, b'synthetic unexecuted Sparkle role')

    def write(self, path, data):
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o600)

    def signing(self, path, team, requirement=None):
        self.assertEqual(team, self.expected['teamIdentifier'])
        return {'codeHash': 'a' * 40, 'requirement': 'synthetic fixed role requirement'}

    def test_all_four_exact_canonical_roles_derive_only_from_actual_verified_bundle_bytes(self):
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing:
            result = INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(len(result), 4)
        self.assertEqual(signing.call_count, 5)
        self.assertEqual({row['role'] for row in result}, set(INPUTS.EXECUTABLES))
        self.assertEqual({row['executable'] for row in result}, {'/Applications/Edith.app/' + INPUTS.PREFIX + relative for relative in INPUTS.EXECUTABLES.values()})
        self.assertEqual(signing.call_args_list[0].args, (self.bundle, self.expected['teamIdentifier'], self.expected['designatedRequirement']))

    def test_wrong_host_or_missing_role_rejects_before_any_role_admission(self):
        self.host.write_bytes(b'different synthetic host')
        with patch.object(INPUTS.INPUTS, 'signing') as signing, self.assertRaisesRegex(ValueError, 'host executable differs'):
            INPUTS.roles(self.bundle, self.expected)
        signing.assert_not_called()
        self.expected['hostExecutableSHA256'] = hashlib.sha256(self.host.read_bytes()).hexdigest()
        (self.bundle / INPUTS.PREFIX / 'Autoupdate').unlink()
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing), self.assertRaises(FileNotFoundError):
            INPUTS.roles(self.bundle, self.expected)

    def test_changed_role_during_signature_check_rejects_even_when_signature_callback_returns(self):
        def changing(path, team, requirement=None):
            result = self.signing(path, team, requirement)
            if path.name == 'Autoupdate':
                path.write_bytes(b'changed synthetic role')
            return result
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=changing), self.assertRaisesRegex(ValueError, 'changed during verification'):
            INPUTS.roles(self.bundle, self.expected)

    def test_symlink_and_hardlinked_role_never_reach_its_signature_check(self):
        role = self.bundle / INPUTS.PREFIX / 'Autoupdate'
        external = self.root / 'external'
        self.write(external, b'synthetic untouched')
        role.unlink()
        role.symlink_to(external)
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing, self.assertRaises(ValueError):
            INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(signing.call_count, 1)
        self.assertEqual(external.read_bytes(), b'synthetic untouched')
        role.unlink()
        os.link(external, role)
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing, self.assertRaises(ValueError):
            INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(signing.call_count, 1)
        self.assertEqual(external.read_bytes(), b'synthetic untouched')


    def context(self, generation, prerelease):
        cases_spec = importlib.util.spec_from_file_location('sparkle_cases', Path(__file__).with_name('test-production-host-cohort.py'))
        cases = importlib.util.module_from_spec(cases_spec)
        cases_spec.loader.exec_module(cases)
        request = cases.synthetic_request()
        expected = request['hosts'][generation]
        expected['hostExecutableSHA256'] = self.expected['hostExecutableSHA256']
        self.write(self.root / 'Edith.dmg', b'synthetic unmounted disk image')
        expected['dmgBytes'] = (self.root / 'Edith.dmg').stat().st_size
        expected['dmgSHA256'] = hashlib.sha256((self.root / 'Edith.dmg').read_bytes()).hexdigest()
        return {'request': request, 'generation': generation, 'directory': str(self.root), 'releaseChannel': {'id': 41, 'tag_name': expected['tag'], 'target_commitish': expected['source'], 'draft': False, 'prerelease': prerelease}}

    def boundary(self, context):
        expected = context['request']['hosts'][context['generation']]
        def command(arguments, timeout=60):
            if arguments[0] == 'git':
                self.assertIn(arguments, [['git', '-C', str(INPUTS.INPUTS.ROOT), 'rev-parse', 'refs/tags/' + expected['tag']], ['git', '-C', str(INPUTS.INPUTS.ROOT), 'rev-parse', 'refs/remotes/origin/main']])
                return expected['source'] + '\n'
            self.assertEqual(arguments[0], 'hdiutil')
            if arguments[1] == 'attach':
                shutil.copytree(self.bundle, self.root / 'sparkle-mounted/Edith.app')
            else:
                self.assertEqual(arguments, ['hdiutil', 'detach', str(self.root / 'sparkle-mounted')])
                shutil.rmtree(self.root / 'sparkle-mounted')
            return ''
        return patch.object(INPUTS.INPUTS, 'command', side_effect=command)

    def test_full_context_routes_stable_and_prerelease_through_existing_release_validator(self):
        for generation in ['previous', 'current']:
            for prerelease in [False, True]:
                with self.subTest(generation=generation, prerelease=prerelease):
                    context = self.context(generation, prerelease)
                    serializer = Path(__file__).parent / 'hosted-public-release/production-inputs.mjs'
                    program = 'import {readFileSync} from "node:fs";import {productionHostReleaseContext} from ' + json.dumps(serializer.resolve().as_uri()) + ';const v=JSON.parse(readFileSync(0,"utf8"));console.log(JSON.stringify(productionHostReleaseContext(v.request,v.generation,v.directory,v.releaseChannel)));'
                    serialized = json.loads(subprocess.check_output(['bun', '--eval', program], input=json.dumps(context).encode(), timeout=10))
                    self.assertEqual(serialized, context)
                    context = serialized
                    expected = context['request']['hosts'][generation]
                    self.expected['teamIdentifier'] = expected['teamIdentifier']
                    def historical(root, actual, *, prerelease=False):
                        self.assertEqual(root, INPUTS.INPUTS.ROOT)
                        self.assertEqual(actual, expected)
                        self.assertEqual(prerelease, context['releaseChannel']['prerelease'])
                        return {'tagTargetCommit': expected['source'], 'latestMainRequired': False}
                    def qualify(root, source, tag, version, build, checksum):
                        self.assertEqual((root, source, tag, version, build, checksum), (str(INPUTS.INPUTS.ROOT), expected['source'], expected['tag'], expected['version'], str(expected['build']), expected['dmgSHA256']))
                        return {'tagTargetCommit': expected['source']}
                    original_command = self.boundary(context)
                    with original_command, patch.object(INPUTS.INPUTS, 'historical_tag', side_effect=historical) as historical_check, patch.object(INPUTS.INPUTS.STATIC, 'qualify_tag', side_effect=qualify) as stable_check, patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing):
                        result = INPUTS.verify(context)
                    self.assertEqual(len(result), 4)
                    self.assertEqual(historical_check.call_count, int(generation == 'previous' or prerelease))
                    self.assertEqual(stable_check.call_count, int(generation == 'current' and not prerelease))

    def test_missing_unknown_or_foreign_channel_rejects_before_mount_or_role_admission(self):
        context = self.context('previous', True)
        invalid = []
        missing = copy.deepcopy(context)
        missing.pop('releaseChannel')
        invalid.append(missing)
        for value in [None, [], True]:
            changed = copy.deepcopy(context)
            changed['releaseChannel'] = value
            invalid.append(changed)
        unknown = copy.deepcopy(context)
        unknown['verified'] = True
        invalid.append(unknown)
        for change in [{'id': 0}, {'tag_name': 'v0.0.999'}, {'draft': True}, {'prerelease': 'true'}, {'target_commitish': 'f' * 40}, {'extraSuccess': True}]:
            changed = copy.deepcopy(context)
            changed['releaseChannel'].update(change)
            invalid.append(changed)
        for changed in invalid:
            with self.subTest(context=changed['releaseChannel'] if 'releaseChannel' in changed else None), self.boundary(context) as command, patch.object(INPUTS.INPUTS, 'historical_tag') as historical, patch.object(INPUTS.INPUTS.STATIC, 'qualify_tag') as stable, patch.object(INPUTS, 'roles') as roles, self.assertRaises(ValueError):
                INPUTS.verify(changed)
            self.assertFalse(any(call.args[0][0] == 'hdiutil' for call in command.call_args_list))
            historical.assert_not_called()
            stable.assert_not_called()
            roles.assert_not_called()

    def test_pending_or_supplied_completed_context_cannot_reach_release_or_native_admission(self):
        context = self.context('previous', True)
        context['request']['schema'] = 2
        with patch.object(INPUTS.INPUTS, 'release_tag') as release, patch.object(INPUTS, 'roles') as roles, self.assertRaises(ValueError):
            INPUTS.verify(context)
        release.assert_not_called()
        roles.assert_not_called()


if __name__ == '__main__':
    unittest.main()
