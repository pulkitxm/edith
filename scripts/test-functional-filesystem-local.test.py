import contextlib
import copy
import io
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('filesystem_local', Path(__file__).with_name('test-functional-filesystem-local.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FilesystemLocalTests(unittest.TestCase):
    def test_xctest_image_requires_root_ownership_single_link_and_immutable_executable(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary).resolve()
            image = root / 'synthetic-xctest'
            image.write_bytes(b'synthetic unexecuted test runner')
            image.chmod(0o755)
            def root_owned(path):
                value = path.lstat()
                names = ['st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size',
                         'st_mtime_ns', 'st_ctime_ns']
                fields = {name: getattr(value, name) for name in names}
                fields['st_uid'] = 0
                return SimpleNamespace(**fields)
            self.assertEqual(fixture.image_identity(image, root_owned)[3], 0)
            with self.assertRaises(ValueError):
                fixture.image_identity(image)
            for mode in [0o777, 0o644]:
                image.chmod(mode)
                with self.assertRaises(ValueError):
                    fixture.image_identity(image, root_owned)
            image.chmod(0o755)
            os.link(image, root / 'hardlink')
            with self.assertRaises(ValueError):
                fixture.image_identity(image, root_owned)
            (root / 'hardlink').unlink()
            alias = root / 'alias'
            alias.symlink_to(image)
            with self.assertRaises(ValueError):
                fixture.image_identity(alias, root_owned)

    def test_only_six_actual_case_passes_qualify(self):
        methods = re.findall(r'\bfunc (test\w+)\(', (fixture.ROOT / fixture.SOURCE).read_text())
        self.assertEqual(len(methods), 6)
        text = '\n'.join([
            *(f"Test Case '-[FunctionalProducerModelTests.FunctionalProducerFilesystemTests {name}]' passed (0.001 seconds)." for name in methods),
            "Test Suite 'FunctionalProducerFilesystemTests' passed at 2026-01-01 00:00:00.",
            'Executed 6 tests, with 0 failures (0 unexpected) in 0.006 seconds',
        ])
        self.assertTrue(fixture.completion(text, methods))
        for changed in ['', text.replace('6 tests', '0 tests'), text.replace('0 failures', '1 failures'),
                        text.replace(methods[0], 'testForeign'), text + '\nIssue recorded',
                        text + '\n' + text.splitlines()[0], text.replace('FunctionalProducerModelTests.', 'ForeignTests.'),
                        text + "\nTest Case '-[ForeignTests testForeign]' passed (0.001 seconds)."]:
            self.assertFalse(fixture.completion(changed, methods))

    def test_command_uses_exact_scope_private_caches_and_one_compiler(self):
        class Driver:
            developer = Path('/synthetic/developer')

            def validate(self):
                return Path('/synthetic/swift-build')
        root = Path('/synthetic/fixture')
        command = fixture.build_arguments(Driver(), root, root / 'build')
        self.assertEqual(command[0], '/synthetic/swift-build')
        self.assertEqual(command[1], '--build-tests')
        self.assertNotIn('--filter', command)
        self.assertEqual(command[command.index('--jobs') + 1], '1')
        self.assertNotIn('--no-parallel', command)
        self.assertNotIn('test', command)
        self.assertNotIn('--skip-build', command)
        for name in ['build', 'cache', 'config', 'security']:
            self.assertIn(str(root / name), command)

    def test_only_authenticated_xctest_image_counts_and_parent_environment_restores(self):
        original = dict(os.environ)
        image = Path('/synthetic/selected/xctest')
        child_environment = {'HOME': '/synthetic/private'}
        def run(command, root, environment, output, **options):
            self.assertEqual(dict(os.environ), child_environment)
            self.assertTrue(options['testing_process'](str(image)))
            for foreign in ['/synthetic/foreign/xctest', '/synthetic/selected/swift', 'xctest']:
                self.assertFalse(options['testing_process'](foreign))
            raise OSError('synthetic failure')
        with patch.object(fixture.native, 'run_original', side_effect=run):
            with self.assertRaises(OSError):
                fixture.execute(['synthetic'], child_environment, Path('/synthetic/output'), image)
        self.assertEqual(dict(os.environ), original)


    def methods(self):
        return re.findall(r'\bfunc (test\w+)\(', (fixture.ROOT / fixture.SOURCE).read_text())

    def clean_result(self):
        return {'exitCode': 0, 'timedOut': False, 'logBoundExceeded': False, 'failure': None,
                'testsCompleted': True, 'observedTestingProcess': False,
                'cleanup': {'reaped': True, 'remainingOwnedProcesses': 0,
                            'unverifiedOwnedProcesses': 0, 'ownershipErrors': [],
                            'pendingOwnedChildren': 0, 'naturalSurvivorCount': 0}}

    def test_direct_xctest_uses_only_six_exact_identifiers_and_pinned_bundle(self):
        image = Path('/synthetic/Agents/xctest')
        bundle = Path('/synthetic/owned/HostedFunctionalActionsPackageTests.xctest')
        methods = self.methods()
        command = fixture.test_arguments(image, bundle, methods)
        self.assertEqual(command, [str(image), '-XCTest', ','.join(
            'FunctionalProducerModelTests.' + fixture.SUITE + '/' + name for name in methods), str(bundle)])
        self.assertNotIn('swiftpm-xctest-helper', ' '.join(command))
        for changed in [methods[:5], methods + ['testForeign'], methods[:-1] + [methods[0]],
                        methods[:-1] + ['Foreign/testForeign'], methods[:-1] + ['testBad,Other']]:
            with self.assertRaises(ValueError):
                fixture.test_arguments(image, bundle, changed)

    def test_build_phase_requires_every_strict_cleanup_field(self):
        original = self.clean_result()
        self.assertTrue(fixture.phase_success(original))
        for key, value in [('reaped', False), ('remainingOwnedProcesses', 1),
                           ('unverifiedOwnedProcesses', 1), ('ownershipErrors', ['synthetic']),
                           ('pendingOwnedChildren', 1), ('naturalSurvivorCount', 1)]:
            changed = copy.deepcopy(original)
            changed['cleanup'][key] = value
            self.assertFalse(fixture.phase_success(changed), key)
        for key, value in [('exitCode', True), ('exitCode', 1), ('timedOut', True),
                           ('logBoundExceeded', True), ('failure', 'synthetic')]:
            changed = copy.deepcopy(original)
            changed[key] = value
            self.assertFalse(fixture.phase_success(changed), key)

    def test_shared_deadline_never_renews_between_build_and_test(self):
        with patch.object(fixture.time, 'monotonic', side_effect=[10, 251, 2410, 9]):
            self.assertEqual(fixture.remaining_budget(10), 2400)
            self.assertEqual(fixture.remaining_budget(10), 2159)
            with self.assertRaises(ValueError):
                fixture.remaining_budget(10)
            with self.assertRaises(ValueError):
                fixture.remaining_budget(10)

    def test_owned_bundle_hash_and_metadata_reject_links_replacement_and_growth(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
            build = Path(temporary).resolve()
            bundle = build / (os.uname().machine + '-apple-macosx/debug/HostedFunctionalActionsPackageTests.xctest')
            executable = bundle / 'Contents/MacOS/HostedFunctionalActionsPackageTests'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'synthetic compiled image')
            executable.chmod(0o700)
            value = fixture.bundle_identity(build)
            self.assertEqual(value[:2], (bundle, executable))
            self.assertEqual(value[3], hashlib.sha256(executable.read_bytes()).hexdigest())
            bundle.chmod(0o777)
            with self.assertRaises(ValueError):
                fixture.bundle_identity(build)
            bundle.chmod(0o755)
            executable.write_bytes(b'synthetic changed image')
            self.assertNotEqual(fixture.bundle_identity(build), value)
            os.link(executable, build / 'hardlink')
            with self.assertRaises(ValueError):
                fixture.bundle_identity(build)
            (build / 'hardlink').unlink()
            target = build / 'synthetic-image'
            executable.rename(target)
            executable.symlink_to(target)
            with self.assertRaises(ValueError):
                fixture.bundle_identity(build)
            executable.unlink()
            target.rename(executable)
            original_read = os.read
            changed = False
            def growing_read(descriptor, size):
                nonlocal changed
                result = original_read(descriptor, size)
                if not changed:
                    changed = True
                    with executable.open('ab') as stream:
                        stream.write(b'growth')
                return result
            with patch.object(fixture.os, 'read', side_effect=growing_read):
                with self.assertRaises(ValueError):
                    fixture.bundle_identity(build)

    def test_constructor_authenticated_short_leader_is_observed_without_later_history(self):
        contracts = fixture.module('test-hosted-native-owner-tests')
        for path, expected in [('/synthetic/Agents/xctest', True),
                               ('/synthetic/swiftpm-xctest-helper', False),
                               ('/synthetic/foreign/xctest', False)]:
            with self.subTest(path=path):
                kernel = contracts.Kernel()
                kernel.processes[123] = (123, 100, 7, path, 123, 1, 501, 501)
                def run(command, root, environment, output, **options):
                    owner = options['ownership_factory'](123, 501)
                    self.assertEqual(owner.known[123][3], path)
                    del kernel.processes[123]
                    self.assertEqual(owner.refresh(), [])
                    return self.clean_result()
                with patch.object(fixture.native.watchdog.ctypes, 'CDLL', return_value=kernel), \
                        patch.object(fixture.native.os, 'kill', side_effect=kernel.kill), \
                        patch.object(fixture.native, 'run_original', side_effect=run):
                    value = fixture.execute(['synthetic'], {'HOME': '/synthetic/private'},
                                            Path('/synthetic/output'), Path('/synthetic/Agents/xctest'))
                self.assertEqual(value['constructorObservedTestingProcess'], expected)
                self.assertEqual(value['observedTestingProcess'], expected)
                self.assertEqual(value['passed'], expected)
                self.assertEqual(kernel.signals, [])

    def test_unadmitted_leader_and_failed_cleanup_never_qualify_observation(self):
        def run(command, root, environment, output, **options):
            return self.clean_result()
        with patch.object(fixture.native, 'run_original', side_effect=run):
            value = fixture.execute(['synthetic'], {}, Path('/synthetic/output'), Path('/synthetic/Agents/xctest'))
        self.assertFalse(value['passed'])
        self.assertFalse(value['constructorObservedTestingProcess'])
        identity = (123, 100, 7, '/synthetic/Agents/xctest', 123)
        owner = SimpleNamespace(known={123: identity}, current_seal=lambda pid: (123, 100, 7, 123))
        def failed(command, root, environment, output, **options):
            options['ownership_factory'](123, 501)
            result = self.clean_result()
            result['cleanup']['pendingOwnedChildren'] = 1
            return result
        with patch.object(fixture.native, 'BoundedOwnership', return_value=owner), \
                patch.object(fixture.native, 'run_original', side_effect=failed):
            value = fixture.execute(['synthetic'], {}, Path('/synthetic/output'), Path('/synthetic/Agents/xctest'))
        self.assertTrue(value['constructorObservedTestingProcess'])
        self.assertFalse(value['passed'])


    def test_failed_build_never_executes_tests_or_removes_owned_fixture(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary).resolve()
            source = root / fixture.SOURCE
            source.parent.mkdir(parents=True)
            source.write_text('\n'.join('func ' + name + '() {}' for name in self.methods()))
            class Driver:
                developer = Path('/synthetic/Xcode.app/Contents/Developer')
                def __init__(self, developer, entry):
                    if entry != 'swift-build':
                        raise AssertionError('build alias required')
                    self.validations = 0
                def validate(self):
                    self.validations += 1
                    return Path('/synthetic/swift-build')
            for name in ['scripts/test-functional-filesystem-local.py', 'scripts/hosted-native-owner-tests.py',
                         'scripts/test-account-sdk-local.py', 'scripts/run-host-swift-testing.py',
                         'scripts/hosted-host-tests/watchdog.py']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'synthetic source pin')
            result = self.clean_result()
            result['cleanup']['unverifiedOwnedProcesses'] = 1
            calls = []
            def execute(command, environment, output, image=None, deadline=None):
                calls.append(command)
                (output / 'tests.log').write_bytes(b'synthetic build rejected')
                return result
            with patch.object(fixture, 'ROOT', root), patch.object(fixture.sys, 'argv', ['runner']), \
                    patch.object(fixture.sys, 'platform', 'darwin'), \
                    patch.dict(fixture.os.environ, {'EDITH_LOCAL_CI_ROOT': str(root), 'DEVELOPER_DIR': '/synthetic'}, clear=True), \
                    patch.object(fixture.driver_api, 'SelectedSwiftDriver', Driver), \
                    patch.object(fixture.native.watchdog, 'canonical_path', side_effect=lambda path, **options: path), \
                    patch.object(fixture, 'image_identity', return_value=('synthetic',)), \
                    patch.object(fixture, 'execute_build', side_effect=execute), \
                    patch.object(fixture, 'execute', side_effect=AssertionError('tests must not run')), \
                    patch.object(fixture.isolation, 'verify_source'), \
                    patch.object(fixture, 'bundle_identity', side_effect=AssertionError('artifact must not be used')), \
                    contextlib.redirect_stdout(io.TextIOWrapper(io.BytesIO(), encoding='utf-8')):
                self.assertEqual(fixture.run(), 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][1], '--build-tests')
            storage = root / 'local/filesystem-contracts'
            self.assertEqual(len(list(storage.glob('fixture-*'))), 1)
            self.assertTrue((storage / 'build-receipt.json').is_file())
            receipt = __import__('json').loads((storage / 'last-receipt.json').read_text())
            self.assertFalse(receipt['passed'])
            self.assertFalse(receipt['testsExecuted'])


    def test_build_phase_reuses_maintained_owner_with_exact_remaining_bound_and_cadence(self):
        command = ['/synthetic/swift-build', '--build-tests']
        environment = {'HOME': '/synthetic/private'}
        output = Path('/synthetic/output')
        expected = self.clean_result()
        with patch.object(fixture.isolation, 'run_owned', return_value=expected) as run:
            self.assertIs(fixture.execute_build(command, environment, output, 2176.5), expected)
        run.assert_called_once_with(command, fixture.ROOT, environment, output / 'tests.log',
                                    deadline=2176.5, cadence=0.5)


if __name__ == '__main__':
    unittest.main()
