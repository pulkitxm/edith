from pathlib import Path
import copy
import importlib.util
import os
import plistlib
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('fixture_cleanup', Path(__file__).with_name('cleanup-keep-awake-fixture.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class FixtureCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='keep-awake-cleanup-contract-')
        self.parent = Path(self.temporary.name).resolve()
        self.fixture = self.parent / 'edith-keep-awake-tests.synthetic'
        self.fixture.mkdir(mode=0o700)
        self.mounts = self.fixture.joinpath(*helper.MOUNT_PARTS)
        self.mounts.mkdir(parents=True)
        self.target = self.mounts / 'synthetic-toolchain'
        self.target.mkdir()
        self.value = {'images': [{'system-entities': [
            {'dev-entry': '/dev/disk42'},
            {'dev-entry': '/dev/disk43s1', 'mount-point': str(self.target)},
        ]}]}
        self.live = {self.target}
        self.calls = []
        self.failure = None

    def tearDown(self):
        self.temporary.cleanup()

    def execute(self, arguments):
        self.calls.append(arguments)
        if arguments == ['/usr/bin/hdiutil', 'info', '-plist']:
            return plistlib.dumps(self.value)
        self.assertEqual(arguments[:2], ['/usr/bin/hdiutil', 'detach'])
        self.assertEqual(len(arguments), 3)
        if self.failure:
            raise self.failure
        target = Path(arguments[2])
        self.live.remove(target)
        self.value['images'] = [image for image in self.value['images']
                                if not any(entity.get('mount-point') == str(target)
                                           for entity in image['system-entities'])]
        return b''

    def clean(self, run=None, readonly=None):
        helper.cleanup(self.fixture, run=run or self.execute,
                       mounted=lambda path: Path(path) in self.live,
                       read_only=readonly or (lambda path: True))

    def assert_no_detach(self):
        self.assertFalse(any(arguments[1] == 'detach' for arguments in self.calls))

    def test_only_validated_private_readonly_image_is_normally_detached_and_requeried(self):
        external = self.parent / 'unrelated'
        external.mkdir()
        self.value['images'].append({'system-entities': [
            {'dev-entry': '/dev/disk90s1', 'mount-point': str(external)}]})
        self.clean()
        self.assertEqual(self.calls, [
            ['/usr/bin/hdiutil', 'info', '-plist'],
            ['/usr/bin/hdiutil', 'info', '-plist'],
            ['/usr/bin/hdiutil', 'detach', str(self.target)],
            ['/usr/bin/hdiutil', 'info', '-plist'],
        ])
        self.assertTrue(self.fixture.is_dir())
        self.assertTrue(external.is_dir())
        self.assertEqual(self.live, set())

    def test_empty_inventory_permits_cleanup_without_detach(self):
        self.value = {'images': []}
        self.live = set()
        self.clean()
        self.assertEqual(len(self.calls), 2)
        self.assert_no_detach()

    def test_multiple_owned_images_detach_once_each_after_full_validation(self):
        second = self.mounts / 'second-toolchain'
        second.mkdir()
        self.live.add(second)
        self.value['images'].append({'system-entities': [
            {'dev-entry': '/dev/disk44s1', 'mount-point': str(second)}]})
        self.clean()
        detaches = [args[2] for args in self.calls if args[1] == 'detach']
        self.assertEqual(sorted(detaches), sorted([str(self.target), str(second)]))
        self.assertEqual(self.live, set())

    def test_unknown_fixture_mount_and_shared_image_reject_before_any_detach(self):
        for kind in ['unknown', 'shared', 'nested']:
            with self.subTest(kind=kind):
                self.calls = []
                original = copy.deepcopy(self.value)
                point = self.fixture / 'other' if kind == 'unknown' else self.parent / 'shared'
                if kind == 'nested':
                    point = self.target / 'nested'
                point.mkdir(exist_ok=True)
                self.value['images'][0]['system-entities'].append(
                    {'dev-entry': '/dev/disk45s1', 'mount-point': str(point)})
                with self.assertRaises(ValueError):
                    self.clean()
                self.assert_no_detach()
                self.value = original

    def test_unreported_mount_under_fixture_rejects_before_detach(self):
        point = self.fixture / 'foreign-mount'
        point.mkdir()
        self.live.add(point)
        with self.assertRaisesRegex(ValueError, 'Unknown mounted'):
            self.clean()
        self.assert_no_detach()

    def test_writable_or_unmounted_target_rejects_before_detach(self):
        with self.assertRaises(ValueError):
            self.clean(readonly=lambda path: False)
        self.assert_no_detach()
        self.live = set()
        with self.assertRaises(ValueError):
            self.clean()
        self.assert_no_detach()

    def test_symlinked_root_ancestor_or_mount_rejects_before_detach(self):
        alias = self.parent / 'edith-keep-awake-tests.alias'
        alias.symlink_to(self.fixture, target_is_directory=True)
        with self.assertRaises(ValueError):
            helper.cleanup(alias, run=self.execute)
        self.assert_no_detach()
        self.target.rmdir()
        self.target.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.clean()
        self.assert_no_detach()
        self.target.unlink()
        self.target.mkdir()
        original = self.fixture / 'Library'
        relocated = self.fixture / 'actual-library'
        original.rename(relocated)
        original.symlink_to(relocated, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.clean()
        self.assert_no_detach()

    def test_nonprivate_or_wrong_scope_root_rejects_before_inventory(self):
        self.fixture.chmod(0o755)
        with self.assertRaises(ValueError):
            self.clean()
        self.assertEqual(self.calls, [])
        self.fixture.chmod(0o700)
        with self.assertRaises(ValueError):
            helper.cleanup(self.parent, run=self.execute)
        self.assertEqual(self.calls, [])

    def test_invalid_devices_duplicate_entries_and_noncanonical_mounts_reject(self):
        original = copy.deepcopy(self.value)
        for device in ['/dev/disk42;false', '/dev/diskx', 'disk42', '/dev/rdisk42']:
            self.value = copy.deepcopy(original)
            self.value['images'][0]['system-entities'][0]['dev-entry'] = device
            with self.assertRaises(ValueError):
                self.clean()
            self.assert_no_detach()
        self.value = copy.deepcopy(original)
        self.value['images'].append(copy.deepcopy(self.value['images'][0]))
        with self.assertRaises(ValueError):
            self.clean()
        self.assert_no_detach()
        self.value = copy.deepcopy(original)
        self.value['images'][0]['system-entities'][1]['mount-point'] = str(self.mounts) + '/./synthetic-toolchain'
        with self.assertRaises(ValueError):
            self.clean()
        self.assert_no_detach()

    def test_inventory_and_output_bounds_reject_without_detach(self):
        for value in [{}, {'images': {}}, {'images': [{}]}, {'images': []}]:
            raw = b'x' * (helper.LIMIT + 1) if value == {'images': []} else plistlib.dumps(value)
            with self.assertRaises(ValueError):
                helper.inventory(raw, self.fixture)
        self.assert_no_detach()

    def test_inventory_device_drift_or_root_mode_change_stops_before_detach(self):
        for kind in ['device', 'root']:
            with self.subTest(kind=kind):
                self.calls = []
                original = copy.deepcopy(self.value)
                def changed(arguments):
                    if len(self.calls) == 1:
                        if kind == 'device':
                            self.value['images'][0]['system-entities'][1]['dev-entry'] = '/dev/disk99s1'
                        else:
                            self.fixture.chmod(0o755)
                    return self.execute(arguments)
                with self.assertRaises(ValueError):
                    self.clean(run=changed)
                self.assert_no_detach()
                self.fixture.chmod(0o700)
                self.value = original

    def test_detach_failure_is_not_ignored_and_remaining_mount_rejects(self):
        self.failure = RuntimeError('synthetic busy volume')
        with self.assertRaisesRegex(RuntimeError, 'synthetic busy'):
            self.clean()
        self.assertEqual(len([args for args in self.calls if args[1] == 'detach']), 1)
        self.failure = None
        self.calls = []
        def ineffective(arguments):
            if arguments[1] == 'detach':
                self.calls.append(arguments)
                return b''
            return self.execute(arguments)
        with self.assertRaisesRegex(ValueError, 'remain after detach'):
            self.clean(run=ineffective)
        self.assertTrue(self.target in self.live)


if __name__ == '__main__':
    unittest.main()
