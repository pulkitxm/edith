import base64
import datetime
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('camera_release', Path(__file__).with_name('prepare-camera-extension-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class CameraReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        self.output = self.folder / 'environment'
        self.output.touch()
        self.certificate = b'synthetic-certificate'
        self.team = 'TEAM123456'
        self.identity = f'Apple Development: Synthetic ({self.team})'
        self.environment = {'EXTENSION_SIGN_IDENTITY': self.identity,
                            'RUNNER_TEMP': str(self.folder), 'GITHUB_ENV': str(self.output)}
        self.profiles = {}
        for secret, _, identifier, entitlement in release.PROFILE_SETTINGS:
            entitlements = {'com.apple.application-identifier': f'{self.team}.{identifier}',
                            'com.apple.security.application-groups': [f'{self.team}.com.pulkit.edith.camera']}
            if entitlement:
                entitlements[entitlement] = True
            profile = {'Entitlements': entitlements, 'TeamIdentifier': [self.team],
                       'ExpirationDate': datetime.datetime.now() + datetime.timedelta(days=30),
                       'DeveloperCertificates': [self.certificate], 'ProvisionedDevices': ['SYNTHETIC-MAC']}
            self.profiles[identifier] = profile
            self.environment[secret] = base64.b64encode(plistlib.dumps(profile)).decode()
        self.commands = []
        self.details = f'Identifier=com.pulkit.edith\nTeamIdentifier={self.team}\n'.encode()

    def tearDown(self):
        self.temporary.cleanup()

    def run_command(self, *arguments):
        self.commands.append(arguments)
        if arguments[:2] == ('security', 'find-certificate'):
            return f'SHA-1 hash: {hashlib.sha1(self.certificate).hexdigest()}'.encode()
        if arguments[0] == 'system_profiler':
            return b'Provisioning UDID: SYNTHETIC-MAC\n'
        if arguments[:2] == ('security', 'cms'):
            return Path(arguments[-1]).read_bytes()
        if arguments[0] == 'python3':
            Path(arguments[3]).mkdir()
        if arguments[:2] == ('codesign', '-dvv'):
            return self.details
        return b''

    def update_profile(self, identifier, change):
        change(self.profiles[identifier])
        secret = next(secret for secret, _, value, _ in release.PROFILE_SETTINGS if value == identifier)
        self.environment[secret] = base64.b64encode(plistlib.dumps(self.profiles[identifier])).decode()

    def test_prepares_production_host_and_private_profile_paths(self):
        values = release.prepare(self.environment, self.run_command)
        self.assertEqual(values['CAMERA_SIGN_TEAM'], self.team)
        self.assertTrue(Path(values['EXTENSION_CONTAINING_HOST_APP']).is_dir())
        for variable in ('CAMERA_CARRIER_PROFILE', 'CAMERA_EXTENSION_PROFILE'):
            self.assertEqual(Path(values[variable]).stat().st_mode & 0o777, 0o600)
        packaging = next(command for command in self.commands if command[0] == 'python3')
        self.assertEqual(packaging[-3:], ('--identity', self.identity, '--release'))
        self.assertIn('CAMERA_SIGN_TEAM=TEAM123456\n', self.output.read_text())
        self.assertNotIn('PROVISIONING_PROFILE=', self.output.read_text())

    def test_missing_credentials_fail_before_packaging(self):
        for secret, _, _, _ in release.PROFILE_SETTINGS:
            del self.environment[secret]
        with self.assertRaisesRegex(ValueError, 'CAMERA_CARRIER_PROVISIONING_PROFILE, CAMERA_EXTENSION_PROVISIONING_PROFILE'):
            release.prepare(self.environment, self.run_command)
        self.assertEqual(self.commands, [])

    def test_ad_hoc_or_unrecognized_identity_is_never_a_release_fallback(self):
        for identity in ('', '-', 'unrecognized'):
            self.environment['EXTENSION_SIGN_IDENTITY'] = identity
            with self.assertRaisesRegex(ValueError, 'never ad hoc'):
                release.prepare(self.environment, self.run_command)

    def test_installed_profile_paths_are_copied_to_private_owned_paths(self):
        for secret, variable, identifier, _ in release.PROFILE_SETTINGS:
            source = self.folder / f'{variable}.provisionprofile'
            source.write_bytes(base64.b64decode(self.environment.pop(secret)))
            self.environment[variable] = str(source)
        values = release.prepare(self.environment, self.run_command)
        self.assertNotEqual(values['CAMERA_CARRIER_PROFILE'], self.environment['CAMERA_CARRIER_PROFILE'])

    def test_rejects_wrong_host_identity_or_missing_team(self):
        for details in (b'Identifier=com.other\nTeamIdentifier=TEAM123456\n', b'Identifier=com.pulkit.edith\nTeamIdentifier=not set\n'):
            self.details = details
            with self.assertRaisesRegex(ValueError, 'production identifier'):
                release.prepare(self.environment, self.run_command)
            self.assertEqual(self.output.read_text(), '')
            self.assertEqual(list(self.folder.glob('camera-release-*')), [])

    def test_profile_admission_rejects_each_material_mismatch(self):
        changes = [
            lambda value: value.update(TeamIdentifier=['OTHER12345']),
            lambda value: value['Entitlements'].update({'com.apple.application-identifier': 'TEAM123456.com.other'}),
            lambda value: value.update(ExpirationDate=datetime.datetime(2020, 1, 1)),
            lambda value: value.update(ProvisionedDevices=['OTHER-MAC']),
            lambda value: value.update(DeveloperCertificates=[b'other-certificate']),
            lambda value: value['Entitlements'].pop('com.apple.developer.system-extension.install'),
            lambda value: value['Entitlements'].update({'com.apple.security.application-groups': []}),
        ]
        identifier = 'com.pulkit.edith.cameraCarrier'
        original = plistlib.dumps(self.profiles[identifier])
        for change in changes:
            with self.subTest(change=changes.index(change)):
                self.profiles[identifier] = plistlib.loads(original)
                self.update_profile(identifier, change)
                with self.assertRaisesRegex(ValueError, 'CAMERA_CARRIER_PROFILE'):
                    release.prepare(self.environment, self.run_command)
                self.assertEqual(self.output.read_text(), '')
                self.assertEqual(list(self.folder.glob('camera-release-*')), [])

    def test_malformed_or_oversized_secret_is_rejected(self):
        for value in ('invalid-base64!', 'a' * 3_000_001, ''):
            self.environment['CAMERA_CARRIER_PROVISIONING_PROFILE'] = value
            with self.assertRaises(ValueError):
                release.prepare(self.environment, self.run_command)

    def test_development_freezes_only_a_synthetic_identity_without_release_secrets(self):
        source = self.folder / 'local/minimal-host/Edith.app/Contents'
        source.mkdir(parents=True)
        (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.pulkit.edith'}))
        previous = Path.cwd()
        try:
            os.chdir(self.folder)
            values = release.prepare_development(self.environment, self.run_command)
        finally:
            os.chdir(previous)
        identifier = plistlib.loads((Path(values['EXTENSION_CONTAINING_HOST_APP']) / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        self.assertTrue(identifier.startswith('com.pulkit.edith.tests.release-'))
        self.assertEqual(list(values), ['EXTENSION_CONTAINING_HOST_APP'])
        self.assertIn(('codesign', '--force', '--sign', '-', values['EXTENSION_CONTAINING_HOST_APP']), self.commands)


if __name__ == '__main__':
    unittest.main()
