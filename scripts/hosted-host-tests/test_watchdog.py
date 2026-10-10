import importlib.util
import json
import time
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


spec = importlib.util.spec_from_file_location('watchdog', Path(__file__).with_name('watchdog.py'))
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


class WatchdogTests(unittest.TestCase):
    def test_admission_requires_exact_hosted_ref_and_source(self):
        environment = {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
                       'RUNNER_ENVIRONMENT': 'github-hosted', 'EDITH_HOSTED_HOST_TESTS': '1',
                       'GITHUB_REPOSITORY': 'pulkitxm/edith',
                       'GITHUB_REF': 'refs/heads/feat/hosted-host-test-diagnostics',
                       'GITHUB_ACTOR_ID': '65671483', 'EDITH_HOSTED_RELEASE': 'false',
                       'EDITH_HOSTED_REBUILD': '', 'EXPECTED_SOURCE_SHA': 'a' * 40}
        watchdog.admit(environment, 'a' * 40)
        for ref in ['refs/heads/main', 'refs/heads/feat/extension-marketplace',
                    'refs/heads/feat/hosted-host-test-diagnostics']:
            for actor in ['65671483', '320458784']:
                watchdog.admit({**environment, 'GITHUB_REF': ref, 'GITHUB_ACTOR_ID': actor}, 'a' * 40)
        for ref in ['refs/heads/feature', 'refs/tags/main', 'refs/pull/1220/merge']:
            with self.assertRaises(ValueError):
                watchdog.admit({**environment, 'GITHUB_REF': ref}, 'a' * 40)
        for key in environment:
            with self.subTest(key=key), self.assertRaises(ValueError):
                watchdog.admit({**environment, key: 'invalid'}, 'a' * 40)
        with self.assertRaises(ValueError):
            watchdog.admit(environment, 'b' * 40)

    def test_required_batches_use_official_helper_arguments_and_remain_serial(self):
        developer = '/Applications/Xcode_26.6.app/Contents/Developer'
        helper = developer + '/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
        bundle = '/owned/.build/debug/EdithHostPackageTests.xctest'
        for batch in ['transport', 'core', 'ui']:
            command = watchdog.command(batch, developer, helper, bundle)
            self.assertEqual(command[:4], [helper, '--test-bundle-path', bundle, 'test'])
            self.assertEqual(command[-3:], [bundle, '--testing-library', 'swift-testing'])
            self.assertIn('--no-parallel', command)
            self.assertIn('--skip-build', command)
            self.assertEqual(command[command.index('--jobs') + 1], '1')
        core = watchdog.command('core', developer, helper, bundle)
        ui = watchdog.command('ui', developer, helper, bundle)
        self.assertIn('HostLifecycleHarnessTests', core[core.index('--filter') + 1])
        self.assertNotIn('EdithHostUITests', core[core.index('--filter') + 1])
        self.assertEqual(ui[ui.index('--filter') + 1], '^EdithHostUITests\\.')
        with self.assertRaises(ValueError):
            watchdog.command('ui', developer)
        with self.assertRaises(KeyError):
            watchdog.command('unknown', developer, helper, bundle)

    def test_selected_toolchain_and_native_bundle_are_canonical_and_environment_matches_swiftpm(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            developer = root / 'Xcode.app/Contents/Developer'
            toolchain = developer / 'Toolchains/XcodeDefault.xctoolchain'
            helper = toolchain / 'usr/libexec/swift/pm/swiftpm-testing-helper'
            package = root / 'Packages/EdithHost'
            binary = package / '.build/arm64-apple-macosx/debug'
            bundle = binary / 'EdithHostPackageTests.xctest'
            executable = bundle / 'Contents/MacOS/EdithHostPackageTests'
            platform = developer / 'Platforms/MacOSX.platform/Developer'
            testing = toolchain / 'usr/lib/swift/macosx/testing'
            for directory in [helper.parent, executable.parent, platform / 'Library/Frameworks',
                              platform / 'Library/PrivateFrameworks', platform / 'usr/lib', testing]:
                directory.mkdir(parents=True)
            for path in [helper, executable]:
                path.write_bytes(b'synthetic-unexecuted')
                path.chmod(0o700)
            environment = {'DYLD_LIBRARY_PATH': '/existing/library',
                           'DYLD_FRAMEWORK_PATH': '/existing/framework', 'SYNTHETIC': 'retained'}
            selected, loaded, image, actual = watchdog.runtime_contract(developer, binary, package, environment)
            self.assertEqual((selected, loaded, image), (helper, bundle, executable))
            self.assertEqual(actual['DYLD_LIBRARY_PATH'],
                             ':'.join(['/existing/library', str(testing), str(platform / 'usr/lib')]))
            self.assertEqual(actual['DYLD_FRAMEWORK_PATH'],
                             ':'.join(['/existing/framework', str(platform / 'Library/Frameworks'),
                                       str(platform / 'Library/PrivateFrameworks')]))
            self.assertEqual(actual['NO_COLOR'], '1')
            self.assertEqual(actual['SYNTHETIC'], 'retained')
            self.assertNotIn('NO_COLOR', environment)
            alias = root / 'alias'
            alias.symlink_to(binary, target_is_directory=True)
            with self.assertRaises(ValueError):
                watchdog.runtime_contract(developer, alias, package, environment)
            outside = root / 'foreign/debug'
            outside.mkdir(parents=True)
            with self.assertRaises(ValueError):
                watchdog.runtime_contract(developer, outside, package, environment)
            executable.chmod(0o777)
            with self.assertRaises(ValueError):
                watchdog.runtime_contract(developer, binary, package, environment)
            executable.chmod(0o700)
            executable.unlink()
            executable.symlink_to(helper)
            with self.assertRaises(ValueError):
                watchdog.runtime_contract(developer, binary, package, environment)
            helper.unlink()
            with self.assertRaises(FileNotFoundError):
                watchdog.runtime_contract(developer, binary, package, environment)

    def test_success_failure_and_deadline_remain_truthful(self):
        class Process:
            pid = 123
            returncode = None
            polls = 0

            def poll(self):
                self.polls += 1
                if self.polls > 1:
                    self.returncode = selected
                return self.returncode

            def wait(self, timeout):
                if self.returncode is None:
                    self.returncode = -15
                return self.returncode

        class Ownership:
            def __init__(self, pid, uid):
                self.signals = []
                owners.append(self)

            def refresh(self):
                return []

            def terminate(self, value):
                self.signals.append(value)

        for selected, deadline in [(0, 100), (1, 100), (0, 0)]:
            owners = []
            with tempfile.TemporaryDirectory() as temporary:
                result = watchdog.run_batch('core', ['swift', 'test'], Path(temporary), deadline,
                                            process_factory=lambda *args, **kwargs: Process(),
                                            ownership_factory=Ownership, sleep=lambda _: None)
            self.assertEqual(result['timedOut'], deadline == 0)
            self.assertEqual(result['exitCode'], -15 if deadline == 0 else selected)
            self.assertEqual(len(owners[0].signals), 1 if deadline == 0 else 0)
            self.assertEqual(result['remainingOwnedProcesses'], 0)
            self.assertFalse(result['testsCompleted'])

    def test_runtime_batch_launches_exact_helper_with_validated_environment_and_records_ownership(self):
        environment = {'NO_COLOR': '1', 'DYLD_FRAMEWORK_PATH': '/selected/frameworks'}
        captured = []
        class Process:
            pid = 321
            returncode = None
            polls = 0
            def poll(self):
                self.polls += 1
                if self.polls > 1:
                    self.returncode = 0
                return self.returncode
            def wait(self, timeout):
                return self.returncode
        class Ownership:
            def __init__(self, pid, uid):
                self.known = {pid: (pid, 4, 5, '/selected/swiftpm-testing-helper', pid)}
                self.parents = {pid: None}
                self.alive = True
            def refresh(self):
                result = list(self.known.values()) if self.alive else []
                self.alive = False
                return result
            def terminate(self, value):
                raise AssertionError('Exited synthetic helper must not be signalled')
        def launch(arguments, **options):
            captured.append((arguments, options['env'], options['start_new_session']))
            options['stdout'].write(b'Test run with 9 tests in 1 suite passed after 1 second.\n')
            return Process()
        with tempfile.TemporaryDirectory() as temporary:
            result = watchdog.run_batch('transport', ['/selected/swiftpm-testing-helper'], Path(temporary), 100,
                                        process_factory=launch, ownership_factory=Ownership,
                                        sleep=lambda _: None, environment=environment)
        self.assertEqual(captured, [(['/selected/swiftpm-testing-helper'], environment, True)])
        self.assertTrue(result['observedTestingProcess'])
        self.assertTrue(result['testsCompleted'])
        self.assertEqual(result['remainingOwnedProcesses'], 0)
        self.assertEqual(result['knownOwnedProcesses'][0]['processGroup'], 321)

    def test_lineage_pins_separate_groups_and_retains_owned_reparented_children(self):
        ownership = object.__new__(watchdog.OwnedProcesses)
        ownership.leader = 100
        ownership.known = {}
        ownership.parents = {}
        snapshots = {100: (100, 1, 1, '/owned/swift', 100, 50),
                     101: (101, 2, 2, '/owned/swiftpm-testing-helper', 101, 100),
                     102: (102, 3, 3, '/foreign/process', 777, 900)}
        ownership.snapshot = lambda pid: snapshots.get(pid)
        class Library:
            def proc_listchildpids(self, pid, children, size):
                if pid == 100:
                    children[0], children[1] = 101, 102
                    return 2
                return 0
        ownership.library = Library()
        self.assertEqual(len(ownership.refresh()), 2)
        self.assertNotIn(102, ownership.known)
        self.assertEqual(ownership.known[101][4], 101)
        self.assertEqual(ownership.parents[101], 100)
        with patch.object(watchdog.os, 'kill') as kill:
            ownership.terminate(watchdog.signal.SIGTERM)
            self.assertEqual(sorted(call.args[0] for call in kill.call_args_list), [100, 101])
        snapshots[101] = (*snapshots[101][:5], 1)
        del snapshots[100]
        self.assertEqual(ownership.refresh(), [snapshots[101][:5]])
        snapshots[101] = (101, 9, 9, '/owned/swiftpm-testing-helper', 101, 1)
        self.assertEqual(ownership.refresh(), [])
        self.assertEqual(ownership.conflicts(), [])
        with patch.object(watchdog.os, 'kill') as kill:
            ownership.terminate(watchdog.signal.SIGTERM)
            kill.assert_not_called()
        self.assertEqual(ownership.known[101][1], 2)
        snapshots[101] = (101, 2, 2, '/owned/swiftpm-testing-helper', 999, 1)
        self.assertEqual(ownership.refresh(), [])
        self.assertEqual(ownership.conflicts(), [ownership.known[101]])
        with patch.object(watchdog.os, 'kill') as kill:
            ownership.terminate(watchdog.signal.SIGTERM)
            kill.assert_not_called()

    def test_crash_retention_accepts_only_known_pid_and_exact_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / 'output'
            output.mkdir()
            identity = (123, 4, 5, '/owned/swiftpm-testing-helper')
            for name, pid, executable in [('owned', 123, identity[3]),
                                          ('foreign', 124, identity[3]),
                                          ('changed', 123, '/foreign/executable')]:
                path = directory / f'{name}.ips'
                path.write_text(json.dumps({'bug_type': '309'}) + '\n' +
                                json.dumps({'pid': pid, 'procPath': executable,
                                            'procLaunch': '1970-01-01 00:00:04.000005 +0000'}))
            (directory / 'symlink.ips').symlink_to(directory / 'owned.ips')
            retained = watchdog.owned_crash_reports(directory, output, [identity], time.time() - 1)
            self.assertEqual(retained, ['owned-crash-123-0.ips'])
            self.assertIn('bug_type', (output / retained[0]).read_text())
            self.assertEqual(watchdog.owned_crash_reports(directory, output, [identity], time.time() + 1), [])

    def test_sampling_names_include_actual_swiftpm_helper_and_package_executable(self):
        for name in ['swiftpm-testing', 'swiftpm-testing-helper', 'EdithHostPackageTests']:
            self.assertTrue(watchdog.is_testing_process('/owned/' + name))
        for name in ['swift', 'swift-frontend', 'foreign.xctest', 'other']:
            self.assertFalse(watchdog.is_testing_process('/owned/' + name))

    def test_actual_testing_summaries_require_nonzero_completed_tests(self):
        for text in ['Test run with 644 tests in 92 suites passed after 42 seconds.',
                     'Test run with 1 test in 1 suite passed after 1 second.',
                     'Test run with 2 tests passed after 1 second.',
                     'Executed 3 tests, with 0 failures']:
            self.assertTrue(watchdog.completed_tests('core', text))
        for text in ['', 'Test run with 0 tests passed', 'Executed 0 tests',
                     'Test run with 4 tests started', 'error: unexpected signal code 11']:
            self.assertFalse(watchdog.completed_tests('ui', text))

    def test_public_process_structure_matches_sdk_layout(self):
        self.assertEqual(watchdog.ctypes.sizeof(watchdog.ProcessInfo), 136)


if __name__ == '__main__':
    unittest.main()
