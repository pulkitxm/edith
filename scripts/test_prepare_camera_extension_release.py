import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('camera_release', Path(__file__).with_name('prepare-camera-extension-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class CameraReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        self.output = self.folder / 'environment'
        self.output.touch()
        self.identity = 'Apple Development: Synthetic (TEAM123456)'
        self.environment = {'EXTENSION_SIGN_IDENTITY': self.identity,
                            'RUNNER_TEMP': str(self.folder), 'GITHUB_ENV': str(self.output)}
        self.commands = []
        self.details = b'Identifier=com.pulkit.edith\nTeamIdentifier=TEAM123456\n'

    def tearDown(self):
        self.temporary.cleanup()

    def run_command(self, *arguments):
        self.commands.append(arguments)
        if arguments[0] == 'python3':
            Path(arguments[3]).mkdir()
        if arguments[:2] == ('codesign', '-dvv'):
            return self.details
        return b''

    def test_prepares_signed_host_without_profiles_or_special_capabilities(self):
        values = release.prepare(self.environment, self.run_command)
        self.assertEqual(list(values), ['EXTENSION_CONTAINING_HOST_APP'])
        self.assertTrue(Path(values['EXTENSION_CONTAINING_HOST_APP']).is_dir())
        packaging = next(command for command in self.commands if command[0] == 'python3')
        self.assertEqual(packaging[-3:], ('--identity', self.identity, '--release'))
        self.assertFalse(any(command[0] in ('security', 'system_profiler') for command in self.commands))
        self.assertNotIn('PROFILE', self.output.read_text())

    def test_ad_hoc_or_unrecognized_identity_is_never_a_release_fallback(self):
        for identity in ('', '-', 'unrecognized'):
            self.environment['EXTENSION_SIGN_IDENTITY'] = identity
            with self.assertRaisesRegex(ValueError, 'never ad hoc'):
                release.prepare(self.environment, self.run_command)
        self.assertEqual(self.commands, [])

    def test_requires_existing_environment_file(self):
        for value in ('', str(self.folder / 'missing')):
            self.environment['GITHUB_ENV'] = value
            with self.assertRaisesRegex(ValueError, 'existing environment file'):
                release.prepare(self.environment, self.run_command)
        self.assertEqual(self.commands, [])

    def test_rejects_wrong_host_identity_or_missing_team(self):
        for details in (b'Identifier=com.other\nTeamIdentifier=TEAM123456\n',
                        b'Identifier=com.pulkit.edith\nTeamIdentifier=not set\n'):
            self.details = details
            with self.assertRaisesRegex(ValueError, 'production identifier'):
                release.prepare(self.environment, self.run_command)
            self.assertEqual(self.output.read_text(), '')
            self.assertEqual(list(self.folder.glob('camera-release-*')), [])

    def test_failed_packaging_cleans_owned_directory(self):
        def fail(*arguments):
            raise RuntimeError('synthetic packaging failure')
        with self.assertRaisesRegex(RuntimeError, 'synthetic packaging failure'):
            release.prepare(self.environment, fail)
        self.assertEqual(list(self.folder.glob('camera-release-*')), [])
        self.assertEqual(self.output.read_text(), '')

    def test_failed_signature_verification_does_not_export_host(self):
        def fail(*arguments):
            if arguments[:2] == ('codesign', '--verify'):
                raise RuntimeError('synthetic signature failure')
            return self.run_command(*arguments)
        with self.assertRaisesRegex(RuntimeError, 'signature failure'):
            release.prepare(self.environment, fail)
        self.assertEqual(list(self.folder.glob('camera-release-*')), [])
        self.assertEqual(self.output.read_text(), '')

    def test_environment_paths_cannot_inject_new_variables(self):
        unsafe = self.folder / 'unsafe\nINJECTED=value'
        unsafe.mkdir()
        self.environment['RUNNER_TEMP'] = str(unsafe)
        with self.assertRaisesRegex(ValueError, 'line breaks'):
            release.prepare(self.environment, self.run_command)
        self.assertEqual(self.output.read_text(), '')
        self.assertEqual(list(unsafe.glob('camera-release-*')), [])

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
        host = Path(values['EXTENSION_CONTAINING_HOST_APP'])
        identifier = plistlib.loads((host / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        self.assertTrue(identifier.startswith('com.pulkit.edith.tests.release-'))
        self.assertEqual(list(values), ['EXTENSION_CONTAINING_HOST_APP'])
        self.assertIn(('codesign', '--force', '--sign', '-', str(host)), self.commands)


if __name__ == '__main__':
    unittest.main()
