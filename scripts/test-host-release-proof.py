import base64
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from host_release_proof import appcast_enclosure, collect_proof, collect_toolchain, json_document, main, METADATA_FIELDS, pinned_sources, qualify_source, validate_toolchain


class HostReleaseProofTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / 'Edith.app'
        self.exe = self.bundle / 'Contents/MacOS/Edith'
        self.exe.parent.mkdir(parents=True)
        self.exe.write_bytes(b'synthetic host code')
        self.index = self.bundle / 'Contents/Resources/index.json'
        self.index.parent.mkdir()
        self.index.write_text(json.dumps([{'id': 'owner' + str(i)} for i in range(39)]))
        self.source = 'a' * 40
        self.key = base64.b64encode(bytes(32)).decode()
        self.signature = base64.b64encode(bytes(64)).decode()
        self.info = {'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123', 'SUPublicEDKey': self.key}
        self.metadata = {'sourceCommit': self.source, 'sourceTreeDirty': False, 'configuration': 'Release', 'optimization': 'Osize', 'linkTimeOptimization': 'full', 'architecture': 'arm64', 'hostExecutableSHA256': hashlib.sha256(self.exe.read_bytes()).hexdigest(), 'privatePath': '/private/not-for-artifact', 'certificateName': 'not-for-artifact'}
        self.requirement = 'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"'
        self.details = 'Authority=Apple Development: Synthetic Private Name\nTeamIdentifier=ABCDEFGHIJ\n'
        self.dmg = self.root / 'Edith.dmg'
        self.dmg.write_bytes(b'synthetic DMG payload')
        self.appcast = self.root / 'appcast.xml'
        self.url = 'https://github.com/pulkitxm/edith/releases/download/v1.2.3/Edith.dmg'
        self.xml = f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>123</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure url="{self.url}" length="{self.dmg.stat().st_size}" sparkle:edSignature="{self.signature}" /></item></channel></rss>'
        self.appcast.write_text(self.xml)
        self.commands = []

    def command(self, arguments):
        self.commands.append(arguments)
        if arguments[0:2] == ['codesign', '-dv']:
            return self.details
        if arguments[0:3] == ['codesign', '-d', '-r-']:
            return 'designated => ' + self.requirement + '\n'
        return ''

    def proof(self, notary='skipped', **changes):
        args = {'bundle': self.bundle, 'dmg': self.dmg, 'appcast': self.appcast, 'metadata': self.metadata, 'pinned_info': {'SUPublicEDKey': self.key}, 'expected_index': self.index.read_bytes(), 'source': self.source, 'tag': 'v1.2.3', 'version': '1.2.3', 'build': '123', 'notary': notary, 'run': self.command, 'layout': lambda *args, **kwargs: self.info, 'signature': lambda key, signature, path: None}
        args.update(changes)
        return collect_proof(**args)

    def test_actual_proof_is_static_and_sanitizes_metadata_and_personal_certificate_name(self):
        proof, metadata = self.proof()
        self.assertEqual(proof['sourceCommit'], self.source)
        self.assertEqual(proof['dmgSHA256'], hashlib.sha256(self.dmg.read_bytes()).hexdigest())
        self.assertEqual(proof['certificateCategory'], 'Apple Development')
        self.assertEqual(proof['verifiedDesignatedRequirement'], self.requirement)
        self.assertEqual(proof['notarization'], 'skipped')
        self.assertFalse(proof['publicationVerified'])
        self.assertNotIn('Private Name', json.dumps(proof))
        self.assertNotIn('privatePath', metadata)
        self.assertNotIn('certificateName', metadata)
        self.assertTrue(all(call[0] == 'codesign' for call in self.commands))
        self.commands.clear()
        self.assertEqual(self.proof('verified')[0]['notarization'], 'verified')
        self.assertTrue(any(call[:3] == ['xcrun', 'stapler', 'validate'] for call in self.commands))
        self.assertTrue(any(call[0] == 'spctl' for call in self.commands))

    def test_quoted_designated_team_preserves_exact_verification_requirement(self):
        proof, _ = self.proof()
        self.assertEqual(proof['verifiedDesignatedRequirement'], self.requirement)
        self.assertIn(['codesign', '--verify', '--strict', '-R=' + self.requirement, str(self.bundle)], self.commands)

    def test_unquoted_designated_team_preserves_exact_verification_requirement(self):
        expected = self.requirement
        self.requirement = expected.replace('"ABCDEFGHIJ"', 'ABCDEFGHIJ')
        proof, _ = self.proof()
        self.assertEqual(proof['verifiedDesignatedRequirement'], expected)
        self.assertIn(['codesign', '--verify', '--strict', '-R=' + expected, str(self.bundle)], self.commands)

    def test_designated_requirement_rejects_other_teams_identifiers_and_clauses(self):
        expected = self.requirement
        invalid = [expected.replace('ABCDEFGHIJ', 'FOREIGN000'), expected.replace('com.pulkit.edith', 'com.example.foreign'), expected.replace('anchor apple generic', 'anchor trusted'), expected.replace(' and ', ' or ', 1), expected + ' or true', expected + ' and true', expected.replace('"ABCDEFGHIJ"', '"ABCDEFGHIJ'), expected + '\ndesignated => ' + expected]
        for value in invalid:
            with self.subTest(requirement=value):
                self.requirement = value
                self.commands.clear()
                with self.assertRaisesRegex(ValueError, 'Host designated requirement differs'):
                    self.proof()
                self.assertFalse(any(call[:3] == ['codesign', '--verify', '--strict'] for call in self.commands))

    def builder_metadata(self):
        return {**{name: self.metadata[name] for name in METADATA_FIELDS}, 'hostExecutableSHA256': 'b' * 64, 'xcode': 'Xcode 26.0.1\nBuild version 17A400', 'sdk': '26.0', 'signature': 'ad-hoc'}

    def test_toolchain_uses_final_qualified_hash_and_preserves_builder_signature(self):
        proof, metadata = self.proof()
        builder = self.builder_metadata()
        for signature in ['ad-hoc', 'unsigned']:
            builder['signature'] = signature
            receipt = collect_toolchain(builder, proof, metadata)
            self.assertEqual(receipt['hostExecutableSHA256'], hashlib.sha256(self.exe.read_bytes()).hexdigest())
            self.assertNotEqual(receipt['hostExecutableSHA256'], builder['hostExecutableSHA256'])
            self.assertEqual(receipt['builderSignature'], signature)
            self.assertEqual(proof['certificateCategory'], 'Apple Development')
            self.assertEqual(set(metadata), set(METADATA_FIELDS))
            self.assertEqual(len(metadata), 7)

    def test_toolchain_closed_fields_types_bounds_and_contradictions(self):
        proof, metadata = self.proof()
        builder = self.builder_metadata()
        receipt = collect_toolchain(builder, proof, metadata)
        for name in receipt:
            missing = dict(receipt)
            del missing[name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                validate_toolchain(missing)
        invalid = [{'extra': 1}, {'schema': True}, {'schema': 2}, {'sourceCommit': 'A' * 40}, {'sourceCommit': 1}, {'hostExecutableSHA256': 'b' * 63}, {'hostExecutableSHA256': None}, {'xcode': 'Xcode 26.0\nBuild version ' + 'A' * 257}, {'xcode': []}, {'xcode': 'Xcode 26\nBuild version A'}, {'xcode': 'Xcode 26.0\nBuild version A\nprivate'}, {'sdk': '1.' + '0' * 32}, {'sdk': True}, {'sdk': '26.0 beta'}, {'builderSignature': 'Developer ID'}, {'builderSignature': 1}]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_toolchain({**receipt, **change})
        for change in [{'sourceCommit': 'c' * 40}, {'sourceTreeDirty': True}, {'sourceTreeDirty': 0}, {'signature': 'development certificate'}, {'extra': 'private'}, {'hostExecutableSHA256': 'bad'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                collect_toolchain({**builder, **change}, proof, metadata)
        with self.assertRaises(ValueError):
            collect_toolchain(builder, {**proof, 'hostExecutableSHA256': 'd' * 64}, metadata)
        path = self.root / 'duplicate.json'
        path.write_text('{"schema":1,"schema":1}')
        with self.assertRaises(ValueError):
            json_document(path)

    def test_main_writes_three_closed_outputs_from_separate_builder_metadata(self):
        proof, sanitized = self.proof()
        builder = self.builder_metadata()
        builder_path = self.root / 'builder.json'
        builder_path.write_text(json.dumps(builder))
        (self.root / 'build-metadata.json').write_text(json.dumps({**self.metadata, 'xcode': builder['xcode'], 'sdk': builder['sdk']}))
        output = self.root / 'proof'
        arguments = ['host_release_proof.py', str(self.bundle), str(self.dmg), str(self.appcast), str(output), '--builder-metadata', str(builder_path), '--source', self.source, '--tag', 'v1.2.3', '--version', '1.2.3', '--build', '123', '--notarization', 'skipped']
        with patch('sys.argv', arguments), patch.dict('os.environ', {'GITHUB_SHA': self.source, 'REBUILD': ''}), patch('host_release_proof.pinned_sources', return_value=(self.info, self.index.read_bytes(), False)), patch('host_release_proof.collect_proof', return_value=(proof, sanitized)):
            main()
        self.assertEqual({path.name for path in output.iterdir()}, {'host-release-proof.json', 'build-metadata.json', 'toolchain-provenance.json'})
        self.assertEqual(json_document(output / 'build-metadata.json'), sanitized)
        self.assertEqual(len(json_document(output / 'build-metadata.json')), 7)
        self.assertEqual(json_document(output / 'toolchain-provenance.json'), collect_toolchain(builder, proof, sanitized))

    def test_final_executable_changes_during_qualification_reject(self):
        def changed(key, signature, path):
            self.exe.write_bytes(b'changed synthetic host')
        with self.assertRaisesRegex(ValueError, 'changed during qualification'):
            self.proof(signature=changed)

    def test_toolchain_maximum_bounds_and_raw_builder_missing_fields(self):
        proof, sanitized = self.proof()
        builder = self.builder_metadata()
        prefix = 'Xcode 26.0\nBuild version '
        builder.update(xcode=prefix + 'A' * (256 - len(prefix)), sdk='1.' + '0' * 30)
        receipt = collect_toolchain(builder, proof, sanitized)
        self.assertEqual(len(receipt['xcode']), 256)
        self.assertEqual(len(receipt['sdk']), 32)
        for name in builder:
            missing = dict(builder)
            del missing[name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                collect_toolchain(missing, proof, sanitized)

    def test_wrong_source_version_build_configuration_executable_and_key_fail(self):
        for change in [{'sourceCommit': 'b' * 40}, {'hostExecutableSHA256': 'b' * 64}, {'configuration': 'Debug'}, {'architecture': 'x86_64'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.proof(metadata={**self.metadata, **change})
        for change in [{'version': '1.2.4'}, {'build': '124'}, {'source': 'not-a-commit'}, {'pinned_info': {'SUPublicEDKey': base64.b64encode(bytes([1]) * 32).decode()}}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.proof(**change)

    def test_appcast_rejects_wrong_url_length_version_build_multiple_enclosures_and_entity(self):
        for xml in [self.xml.replace(self.url, 'https://foreign/Edith.dmg'), self.xml.replace('length="21"', 'length="22"'), self.xml.replace('>123<', '>124<'), self.xml.replace('>1.2.3<', '>1.2.4<'), self.xml.replace('</item>', '<enclosure /></item>'), '<!DOCTYPE rss>' + self.xml]:
            with self.subTest(xml=xml), self.assertRaises(ValueError):
                appcast_enclosure(xml.encode(), self.url, '1.2.3', '123', self.dmg.stat().st_size)

    def test_source_index_extra_payload_and_external_link_fail_before_signature(self):
        with self.assertRaises(ValueError):
            self.proof(expected_index=b'[]')
        self.index.write_text(json.dumps([{'id': 'owner' + str(i)} for i in range(38)]))
        with self.assertRaises(ValueError):
            self.proof()
        self.index.write_text(json.dumps([{'id': 'owner' + str(i)} for i in range(39)]))
        payload = self.bundle / 'Contents/Resources/Feature.appex'
        payload.mkdir()
        with self.assertRaises(ValueError):
            self.proof()
        payload.rmdir()
        (self.bundle / 'foreign').symlink_to(self.dmg)
        with self.assertRaises(ValueError):
            self.proof()

    def test_missing_foreign_team_requirement_seal_and_failed_signature_reject(self):
        for details in ['Signature=adhoc\n', 'Authority=Apple Development: Synthetic\nTeamIdentifier=invalid\n']:
            self.details = details
            with self.assertRaises(ValueError):
                self.proof()
        self.details = 'Authority=Apple Development: Synthetic\nTeamIdentifier=ABCDEFGHIJ\n'
        self.requirement = self.requirement.replace('ABCDEFGHIJ', 'FOREIGN000')
        with self.assertRaises(ValueError):
            self.proof()
        self.requirement = self.requirement.replace('FOREIGN000', 'ABCDEFGHIJ')
        def rejected(*args):
            raise subprocess.CalledProcessError(1, 'synthetic rejection')
        with self.assertRaises(subprocess.CalledProcessError):
            self.proof(run=rejected)
        with self.assertRaises(subprocess.CalledProcessError):
            self.proof(signature=rejected)

    def test_release_stamping_requires_only_version_changes_at_exact_source(self):
        original = {'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'SUPublicEDKey': self.key}
        path = self.root / 'Resources/Info.plist'
        path.parent.mkdir()
        path.write_bytes(plistlib.dumps({**original, 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123'}))
        calls = lambda args: self.source + '\n' if args[1] == 'rev-parse' else '' if args[1] == 'ls-files' else 'Resources/Info.plist\n'
        with patch('host_release_proof.document', return_value=path.read_bytes()), patch('host_release_proof.subprocess.check_output', side_effect=[plistlib.dumps(original), plistlib.dumps(original), self.index.read_bytes(), self.index.read_bytes()]):
            self.assertTrue(pinned_sources(self.source, '1.2.3', '123', calls)[2])
        changed = {**original, 'SUPublicEDKey': 'foreign', 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123'}
        with patch('host_release_proof.document', return_value=plistlib.dumps(changed)), patch('host_release_proof.subprocess.check_output', return_value=plistlib.dumps(original)), self.assertRaises(ValueError):
            pinned_sources(self.source, '1.2.3', '123', calls)
        with self.assertRaises(ValueError):
            pinned_sources(self.source, '1.2.3', '123', lambda args: 'b' * 40)
        with patch('host_release_proof.document', return_value=path.read_bytes()), patch('host_release_proof.subprocess.check_output', side_effect=[plistlib.dumps(original), plistlib.dumps(original), self.index.read_bytes(), b'[]']), self.assertRaises(ValueError):
            pinned_sources(self.source, '1.2.3', '123', calls)

    def test_untracked_source_rejects_before_reading_any_tracked_or_built_artifact(self):
        for path in ['Packages/EdithHost/Sources/EdithHost/Unexpected.swift', 'Packages/EdithHost/Sources/NewRole/Unexpected.swift', 'Packages/EdithHost/Sources/EdithHost/with space.swift']:
            calls = []
            def run(arguments):
                calls.append(arguments)
                return self.source + '\n' if arguments[1] == 'rev-parse' else path + '\0'
            with patch('host_release_proof.document') as document, patch('host_release_proof.subprocess.check_output') as read, self.assertRaisesRegex(ValueError, 'Untracked source inputs'):
                pinned_sources(self.source, '1.2.3', '123', run)
            self.assertEqual(calls, [['git', 'rev-parse', 'HEAD'], ['git', 'ls-files', '--others', '--exclude-standard', '-z']])
            document.assert_not_called()
            read.assert_not_called()

    def test_ignored_outputs_allow_clean_source_and_other_tracked_changes_reject(self):
        calls = []
        def clean(arguments):
            calls.append(arguments)
            return self.source + '\n' if arguments[1] == 'rev-parse' else ''
        with patch('host_release_proof.subprocess.check_output', side_effect=[plistlib.dumps(self.info), self.index.read_bytes(), self.index.read_bytes()]):
            self.assertFalse(pinned_sources(self.source, '1.2.3', '123', clean)[2])
        self.assertEqual(calls[:2], [['git', 'rev-parse', 'HEAD'], ['git', 'ls-files', '--others', '--exclude-standard', '-z']])
        self.assertEqual(calls[2], ['git', 'ls-files', '--others', '-z', '--', 'Packages/EdithHost/Sources', 'Packages/ExtensionMarketplace/Sources', 'Packages/ExtensionSupport/Sources', 'Extensions/fixtureSupport', ':(glob,exclude)**/.build/**', ':(glob,exclude)**/.swiftpm/**', ':(glob,exclude)**/.DS_Store'])
        self.assertEqual(calls[3], ['git', 'diff', '--name-only', 'HEAD'])
        def changed(arguments):
            return self.source + '\n' if arguments[1] == 'rev-parse' else '' if arguments[1] == 'ls-files' else 'Packages/EdithHost/Sources/EdithHost/HostEntry.swift\n'
        with patch('host_release_proof.subprocess.check_output') as read, self.assertRaisesRegex(ValueError, 'Unexpected source changes'):
            pinned_sources(self.source, '1.2.3', '123', changed)
        read.assert_not_called()

    def test_ignored_compiled_sources_reject_before_the_stamp_exception(self):
        for path in ['Packages/EdithHost/Sources/EdithHost/Hidden.swift', 'Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/Hidden.swift', 'Packages/ExtensionSupport/Sources/EdithExtensionSupport/Hidden.swift', 'Extensions/fixtureSupport/Hidden.swift']:
            def run(arguments):
                if arguments[1] == 'rev-parse':
                    return self.source + '\n'
                return '' if '--exclude-standard' in arguments else path + '\0'
            with patch('host_release_proof.document') as document, patch('host_release_proof.subprocess.check_output') as read, self.assertRaisesRegex(ValueError, 'Ignored untracked source inputs'):
                pinned_sources(self.source, '1.2.3', '123', run)
            document.assert_not_called()
            read.assert_not_called()

    def test_exact_two_plist_stamp_exception_retains_the_pinned_feed_and_key(self):
        original = {'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'SUPublicEDKey': self.key, 'SUFeedURL': 'https://example.invalid/appcast.xml'}
        paths = ['Resources/Info.plist', 'Resources/HelperInfo.plist']
        stamped = {**original, 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123'}
        def run(arguments):
            return self.source + '\n' if arguments[1] == 'rev-parse' else '' if arguments[1] == 'ls-files' else '\n'.join(paths) + '\n'
        with patch('host_release_proof.document', return_value=plistlib.dumps(stamped)), patch('host_release_proof.subprocess.check_output', side_effect=[plistlib.dumps(original), plistlib.dumps(original), plistlib.dumps(original), self.index.read_bytes(), self.index.read_bytes()]):
            self.assertTrue(pinned_sources(self.source, '1.2.3', '123', run)[2])
        for field in ['SUPublicEDKey', 'SUFeedURL']:
            with patch('host_release_proof.document', return_value=plistlib.dumps({**stamped, field: 'foreign'})), patch('host_release_proof.subprocess.check_output', return_value=plistlib.dumps(original)), self.assertRaisesRegex(ValueError, 'beyond release version stamping'):
                pinned_sources(self.source, '1.2.3', '123', run)

    def test_workflow_records_proof_after_signing_and_stages_exact_receipts_without_executing_host(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        job = workflow.split('  dmg:\n')[1].split('  publish:')[0]
        self.assertLess(job.index('- name: Verify code signatures'), job.index('- name: Record the source-bound static host release proof'))
        self.assertLess(job.index('- name: Verify notarized disk image'), job.index('- name: Record the source-bound static host release proof'))
        self.assertIn('--source "$BUILT_SHA"', job)
        self.assertIn('name: host-release-proof', job)
        self.assertIn('notary=skipped', job)
        self.assertIn('notary=verified', job)
        self.assertIn('cp Edith.dmg release-macos/', job)
        self.assertIn('cp dist/appcast/appcast.xml release-macos/', job)
        self.assertIn('local/host-release-proof/toolchain-provenance.json', job)
        self.assertIn('cp local/host-release-proof/host-release-proof.json local/host-release-proof/build-metadata.json local/host-release-proof/toolchain-provenance.json release-macos/', job)
        script = Path(__file__).with_name('host_release_proof.py').read_text()
        self.assertNotIn('inspect_host', script)
        self.assertNotIn('inspect_cli', script)
        self.assertNotIn('hdiutil', script)

    def test_wrong_workflow_source_rejects_before_any_subprocess_or_artifact(self):
        arguments = ['host_release_proof.py', str(self.bundle), str(self.dmg), str(self.appcast), str(self.root / 'proof'), '--source', self.source, '--tag', 'v1.2.3', '--version', '1.2.3', '--build', '123', '--notarization', 'skipped']
        with patch('sys.argv', arguments), patch.dict('os.environ', {'GITHUB_SHA': 'b' * 40}), patch('host_release_proof.subprocess.run') as execute, self.assertRaises(ValueError):
            main()
        execute.assert_not_called()
        self.assertFalse((self.root / 'proof').exists())

    def test_rebuild_separately_binds_dispatch_and_exact_tag_source_without_current_source_waiver(self):
        current = 'b' * 40
        self.assertEqual(qualify_source(self.source, 'v1.2.3', {'GITHUB_SHA': self.source})['sourceMode'], 'current-workflow-source')
        environment = {'GITHUB_SHA': current, 'REBUILD': 'v1.2.3'}
        result = qualify_source(self.source, 'v1.2.3', environment, lambda args: self.source)
        self.assertEqual(result['workflowSourceCommit'], current)
        self.assertEqual(result['sourceMode'], 'tag-rebuild')
        for variables in [{'GITHUB_SHA': current}, {'GITHUB_SHA': current, 'REBUILD': 'v1.2.4'}, {'GITHUB_SHA': 'invalid', 'REBUILD': 'v1.2.3'}]:
            with self.assertRaises(ValueError):
                qualify_source(self.source, 'v1.2.3', variables, lambda args: self.source)
        with self.assertRaises(ValueError):
            qualify_source(self.source, 'v1.2.3', environment, lambda args: current)


class HostReleaseCryptoTests(unittest.TestCase):
    def test_actual_cryptokit_rejects_changed_payload_key_and_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            generator = root / 'generate.swift'
            generator.write_text('import CryptoKit\nimport Foundation\nlet key = Curve25519.Signing.PrivateKey()\nlet bytes = Data("synthetic signed DMG".utf8)\ntry bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))\nlet output = [key.publicKey.rawRepresentation.base64EncodedString(), try key.signature(for: bytes).base64EncodedString()]\nprint(String(data: try JSONEncoder().encode(output), encoding: .utf8)!)\n')
            payload = root / 'Edith.dmg'
            pair = json.loads(subprocess.check_output(['xcrun', 'swift', str(generator), str(payload)], timeout=180))
            executable = root / 'verify'
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(Path(__file__).with_name('verify-host-release-signature.swift')), '-o', str(executable)], check=True, capture_output=True, timeout=180)
            def verify(key, signature):
                return subprocess.run([str(executable), key, signature, str(payload)], capture_output=True, timeout=30).returncode
            self.assertEqual(verify(*pair), 0)
            self.assertNotEqual(verify(base64.b64encode(bytes(32)).decode(), pair[1]), 0)
            self.assertNotEqual(verify(pair[0], base64.b64encode(bytes(64)).decode()), 0)
            payload.write_bytes(b'changed DMG')
            self.assertNotEqual(verify(*pair), 0)


if __name__ == '__main__':
    unittest.main()
