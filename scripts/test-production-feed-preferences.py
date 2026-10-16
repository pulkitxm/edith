import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).parent / 'hosted-public-release/production-feed-preferences.py'
SPEC = importlib.util.spec_from_file_location('feed_preferences', SOURCE)
FEED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FEED)


class FeedPreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.receipt = self.state / 'sparkle-feed-route.json'
        self.path = self.home / 'Library/Preferences' / FEED.DOMAIN
        self.url = 'https://github.com/pulkitxm/edith/releases/download/v0.0.320/appcast.xml'

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, value):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path.parent.parent.chmod(0o700)
        self.path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
        self.path.chmod(0o600)

    def synchronize(self, value):
        current = plistlib.loads(self.path.read_bytes()) if self.path.exists() else {}
        if value is None:
            current.pop(FEED.KEY, None)
        else:
            current[FEED.KEY] = value
        self.write(current)
        return value

    def setup_route(self):
        return FEED.setup(str(self.home), '0.0.320', str(self.receipt), self.synchronize)

    def restore_route(self):
        return FEED.restore(str(self.home), '0.0.320', str(self.receipt), self.synchronize)

    def test_absent_feed_restores_only_key_and_keeps_new_sparkle_and_layout_state(self):
        self.assertEqual(self.setup_route(), {'route': 'isolated-public-prerelease', 'url': self.url})
        self.write({FEED.KEY: self.url, 'SULastCheckTime': 123, 'layout': {'home': ['synthetic']}, 'time': 8})
        self.assertTrue(self.restore_route()['restored'])
        self.assertEqual(plistlib.loads(self.path.read_bytes()), {'SULastCheckTime': 123, 'layout': {'home': ['synthetic']}, 'time': 8})
        self.assertTrue(self.restore_route()['alreadyOriginal'])

    def test_saved_feed_is_restored_without_reverting_updated_values(self):
        original = 'https://example.invalid/synthetic-original.xml'
        self.write({FEED.KEY: original, 'layout': 1})
        self.setup_route()
        self.write({FEED.KEY: self.url, 'layout': 2, 'SparkleState': b'synthetic'})
        self.restore_route()
        self.assertEqual(plistlib.loads(self.path.read_bytes()), {FEED.KEY: original, 'layout': 2, 'SparkleState': b'synthetic'})

    def test_changed_feed_rejects_without_overwriting_latest_preferences(self):
        self.setup_route()
        self.write({FEED.KEY: 'https://example.invalid/foreign.xml', 'layout': 3})
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            self.restore_route()
        self.assertEqual(self.path.read_bytes(), before)

    def test_wrong_version_and_receipt_identity_reject(self):
        for version in ['v0.0.320', '0.0.320?synthetic', '../0.0.320', '0.0.320/appcast.xml']:
            with self.assertRaises(ValueError):
                FEED.setup(str(self.home), version, str(self.receipt), self.synchronize)
        self.setup_route()
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            FEED.restore(str(self.home), '0.0.321', str(self.receipt), self.synchronize)
        self.assertEqual(self.path.read_bytes(), before)

    def test_second_setup_cannot_replace_original_restoration_record(self):
        self.setup_route()
        record = self.receipt.read_bytes()
        with self.assertRaises(ValueError):
            self.setup_route()
        self.assertEqual(self.receipt.read_bytes(), record)

    def test_symlink_and_hardlink_files_never_modify_target(self):
        self.write({'layout': 1})
        original = self.path.read_bytes()
        target = self.root / 'other.plist'
        self.path.rename(target)
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.setup_route()
        self.assertEqual(target.read_bytes(), original)
        self.path.unlink()
        os.link(target, self.path)
        with self.assertRaises(ValueError):
            self.setup_route()
        self.assertEqual(target.read_bytes(), original)

    def test_unowned_public_directory_file_and_oversize_reject(self):
        self.write({'layout': 1})
        self.path.parent.chmod(0o755)
        with self.assertRaises(ValueError):
            self.setup_route()
        self.path.parent.chmod(0o700)
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            self.setup_route()
        self.path.chmod(0o600)
        self.path.write_bytes(b'x' * (FEED.MAXIMUM + 1))
        with self.assertRaises(ValueError):
            self.setup_route()

    def test_library_symlink_is_not_followed(self):
        target = self.root / 'other-library'
        target.mkdir(mode=0o700)
        (self.home / 'Library').symlink_to(target)
        with self.assertRaises(ValueError):
            self.setup_route()
        self.assertEqual(list(target.iterdir()), [])

    def test_concurrent_replacement_is_detected_before_atomic_commit(self):
        self.write({'layout': 1})
        held = FEED.directory(self.path.parent)
        try:
            _, previous = FEED.read(held, FEED.DOMAIN)
            self.write({'layout': 2})
            current = self.path.read_bytes()
            with self.assertRaises(ValueError):
                FEED.replace(held, FEED.DOMAIN, plistlib.dumps({'layout': 3}), previous)
            self.assertEqual(self.path.read_bytes(), current)
            self.assertFalse(any(path.name.startswith('.feed-') for path in self.path.parent.iterdir()))
        finally:
            os.close(held)

    def test_partial_setup_failure_retains_rollback_record_and_restores_only_key(self):
        def interrupted(value):
            self.synchronize(value)
            raise RuntimeError('Synthetic interruption after commit')
        with self.assertRaises(RuntimeError):
            FEED.setup(str(self.home), '0.0.320', str(self.receipt), interrupted)
        self.assertTrue(self.receipt.exists())
        self.assertTrue(self.restore_route()['restored'])
        self.assertNotIn(FEED.KEY, plistlib.loads(self.path.read_bytes()))

    def test_foreign_receipt_and_fifo_read_fail_bounded(self):
        self.setup_route()
        value = json.loads(self.receipt.read_bytes())
        value['home'] = '/synthetic/foreign'
        self.receipt.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            self.restore_route()
        self.path.unlink()
        os.mkfifo(self.path, 0o600)
        with self.assertRaises(ValueError):
            self.setup_route()

    def test_cli_refuses_local_environment_before_domain_mutation(self):
        environment = {key: value for key, value in os.environ.items() if key in ('PATH', 'TMPDIR', 'XDG_CACHE_HOME')}
        environment['HOME'] = str(self.home)
        result = subprocess.run([sys.executable, '-I', '-B', str(SOURCE), 'setup', str(self.home), '0.0.320', str(self.receipt)], env=environment, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / 'Library').exists())
        self.assertFalse(self.receipt.exists())

    def test_duplicate_receipt_key_is_rejected_without_preference_mutation(self):
        self.setup_route()
        before = self.path.read_bytes()
        self.receipt.write_bytes(self.receipt.read_bytes()[:-1] + b', "schema": 1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.restore_route()
        self.assertEqual(self.path.read_bytes(), before)

    def test_wrong_cache_readback_or_missing_physical_commit_cannot_succeed(self):
        for callback in [lambda _: True, lambda value: value]:
            with self.subTest(callback=callback), self.assertRaises(ValueError):
                FEED.setup(str(self.home), '0.0.320', str(self.receipt), callback)
            self.receipt.unlink()

    def test_single_key_restore_keeps_updates_arriving_during_cache_sync(self):
        self.setup_route()
        def update(value):
            current = plistlib.loads(self.path.read_bytes())
            current.update(SULastCheckTime=999, layout={'home': ['newer-synthetic']})
            self.write(current)
            return self.synchronize(value)
        FEED.restore(str(self.home), '0.0.320', str(self.receipt), update)
        self.assertEqual(plistlib.loads(self.path.read_bytes()), {'SULastCheckTime': 999, 'layout': {'home': ['newer-synthetic']}})

    def test_parent_replacement_during_sync_fails_closed(self):
        self.setup_route()
        def replacement(value):
            parent = self.path.parent
            parent.rename(parent.with_name('retired-preferences'))
            parent.mkdir(mode=0o700)
            return value
        with self.assertRaisesRegex(ValueError, 'parent changed'):
            FEED.restore(str(self.home), '0.0.320', str(self.receipt), replacement)

    def test_native_sync_refuses_local_context_without_loading_core_foundation(self):
        with patch.dict(os.environ, {}, clear=True), patch('ctypes.CDLL') as library:
            with self.assertRaises(ValueError):
                FEED.native_synchronize(self.url)
        library.assert_not_called()

    def test_public_cfpreferences_binding_mutates_only_fixed_key_and_checks_sync(self):
        class Function:
            def __init__(self, callback):
                self.callback = callback
            def __call__(self, *arguments):
                return self.callback(*arguments)
        class Core:
            def __init__(self, synchronized=True):
                self.references = {}
                self.calls = []
                self.value = None
                def string(_, data, length, encoding, external):
                    self.assertions = (len(data) == length and encoding == 0x08000100 and external == 0)
                    reference = len(self.references) + 1
                    self.references[reference] = data.decode()
                    return reference
                def set_value(key, value, domain):
                    self.calls.append((self.references[key], self.references.get(value), self.references[domain]))
                    self.value = value
                def read_string(value, buffer, length, encoding):
                    buffer.value = self.references[value].encode()
                    return 1
                self.CFStringCreateWithBytes = Function(string)
                self.CFPreferencesSetAppValue = Function(set_value)
                self.CFPreferencesAppSynchronize = Function(lambda _: synchronized)
                self.CFPreferencesCopyAppValue = Function(lambda *_: self.value)
                self.CFGetTypeID = Function(lambda _: 7)
                self.CFStringGetTypeID = Function(lambda: 7)
                self.CFStringGetCString = Function(read_string)
                self.CFRelease = Function(lambda _: None)
        for value in [self.url, None]:
            core = Core()
            with patch.object(FEED, 'hosted_account'), patch('ctypes.CDLL', return_value=core) as library:
                self.assertEqual(FEED.native_synchronize(value), value)
            library.assert_called_once_with('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
            self.assertEqual(core.calls, [(FEED.KEY, value, 'com.pulkit.edith')])
            self.assertTrue(core.assertions)
        with patch.object(FEED, 'hosted_account'), patch('ctypes.CDLL', return_value=Core(False)):
            with self.assertRaisesRegex(ValueError, 'synchronization failed'):
                FEED.native_synchronize(self.url)


if __name__ == '__main__':
    unittest.main()
