import contextlib
import io
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from host_build_metadata import executable_hash, load_metadata, write_metadata


class ShippingHostVersionTests(unittest.TestCase):
    def setUp(self):
        self.script = Path(__file__).with_name('package-shipping-host.py').resolve()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(self.root)
        self.source = self.root / 'minimal/Edith.app'
        self.destination = self.root / 'shipping/Edith.app'
        self.info = {'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123',
                     'SUPublicEDKey': 'synthetic-public-key', 'SUFeedURL': 'https://example.invalid/appcast.xml',
                     'NSCameraUsageDescription': 'Synthetic camera permission'}
        resources = self.root / 'Resources'
        resources.mkdir()
        (resources / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        (resources / 'HelperInfo.plist').write_bytes(plistlib.dumps(self.info))
        (resources / 'Host.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': False}))
        (resources / 'ed-launcher').write_bytes(b'synthetic launcher')
        for name in ['MacOS', 'Frameworks/Sparkle.framework', 'Resources', 'Extensions']:
            (self.source / 'Contents' / name).mkdir(parents=True, exist_ok=True)
        (self.source / 'Contents/MacOS/Edith').write_bytes(b'synthetic compiled host')
        (self.source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Edith'}))
        self.original = {'sourceCommit': 'a' * 40, 'sourceTreeDirty': False, 'configuration': 'Release',
                         'hostExecutableSHA256': executable_hash(self.source), 'signature': 'ad-hoc'}
        write_metadata(self.source, self.original, 'ad-hoc')
        self.before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.identity = 'Apple Development: Synthetic (SYNTHETIC1)'
        self.commands = []

    def command(self, *arguments):
        self.commands.append(arguments)
        if arguments[0] == 'ditto':
            shutil.copytree(arguments[1], arguments[2], symlinks=True)
        if arguments[0] == 'file':
            return 'Mach-O' if Path(arguments[-1]).name == 'Edith' else 'data'
        if arguments[:2] == ('codesign', '-dvv'):
            return 'TeamIdentifier=SYNTHETIC1\n'
        if arguments[0] == 'codesign' and '--force' in arguments:
            binary = Path(arguments[-1])
            if binary.name == 'Edith' and binary.is_file():
                binary.write_bytes(b'synthetic certificate-signed host')
        return ''

    def package(self, *options):
        argv = [str(self.script), str(self.source), str(self.destination), '--identity', self.identity, *options]
        entitlements = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps({}), stderr=b'')
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()), \
                patch.object(sys, 'argv', argv), patch.dict(os.environ, {'EDITH_HOST_ENTITLEMENTS': ''}), \
                patch('verify_shipping_host.inspect_host') as inspect, \
                patch('verify_shipping_host.run', side_effect=self.command), \
                patch('subprocess.run', return_value=entitlements):
            runpy.run_path(str(self.script), run_name='__main__')
        return inspect

    def unchanged_source(self):
        for name, data in self.before.items():
            self.assertEqual((self.root / name).read_bytes(), data, name)

    def test_resolved_release_version_changes_only_copied_bundle_and_preserves_clean_source_receipt(self):
        self.package('--release', '--version', '1.2.4', '--build', '124')
        info = plistlib.loads((self.destination / 'Contents/Info.plist').read_bytes())
        self.assertEqual((info['CFBundleShortVersionString'], info['CFBundleVersion']), ('1.2.4', '124'))
        self.assertEqual(info['CFBundleIdentifier'], 'com.pulkit.edith')
        for key in ['SUFeedURL', 'SUPublicEDKey', 'NSCameraUsageDescription']:
            self.assertEqual(info[key], self.info[key])
        self.unchanged_source()
        metadata = load_metadata(self.destination)
        self.assertFalse(metadata['sourceTreeDirty'])
        self.assertEqual(metadata['sourceCommit'], self.original['sourceCommit'])
        self.assertNotEqual(metadata['hostExecutableSHA256'], self.original['hostExecutableSHA256'])
        self.assertEqual(metadata['signature'], 'development certificate')
        signatures = [args for args in self.commands if args[:2] == ('codesign', '--force')]
        self.assertGreaterEqual(len(signatures), 2)
        self.assertTrue(all(args[args.index('--sign') + 1] == self.identity for args in signatures))
        self.assertEqual(signatures[-1][-1].endswith('Edith.app'), True)
        self.assertIn('--requirements', signatures[-1])

    def test_default_release_and_development_packages_keep_committed_version_metadata(self):
        for options in [('--release',), ('--slot', 'synthetic')]:
            with self.subTest(options=options):
                self.package(*options)
                info = plistlib.loads((self.destination / 'Contents/Info.plist').read_bytes())
                self.assertEqual((info['CFBundleShortVersionString'], info['CFBundleVersion']), ('1.2.3', '123'))
                self.unchanged_source()

    def test_malformed_or_unpaired_release_metadata_rejects_before_any_packaging_or_signing(self):
        for options in [('--version', '1.2.4'), ('--build', '124'), ('--version', '', '--build', '124'),
                        ('--version', '1.2.4', '--build', ''), ('--version', '1.2.4-beta', '--build', '124'),
                        ('--version', '1.2.4', '--build', '../124'), ('--version', '1.2.4\n', '--build', '124'),
                        ('--version', '1' * 65, '--build', '124'), ('--version', '1.2.4', '--build', '1' * 19)]:
            with self.subTest(options=options), self.assertRaises(SystemExit) as error:
                self.package('--release', *options)
            self.assertEqual(error.exception.code, 2)
            self.assertFalse(self.commands)
            self.assertFalse(self.destination.exists())
            self.unchanged_source()

    def test_explicit_version_metadata_cannot_relabel_a_development_slot(self):
        with self.assertRaises(SystemExit) as error:
            self.package('--slot', 'synthetic', '--version', '1.2.4', '--build', '124')
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.commands)
        self.unchanged_source()


if __name__ == '__main__':
    unittest.main()
