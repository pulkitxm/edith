import importlib.util
import json
import time
import tempfile
import unittest
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
                       'EXPECTED_SOURCE_SHA': 'a' * 40}
        watchdog.admit(environment, 'a' * 40)
        for key in environment:
            with self.subTest(key=key), self.assertRaises(ValueError):
                watchdog.admit({**environment, key: 'invalid'}, 'a' * 40)
        with self.assertRaises(ValueError):
            watchdog.admit(environment, 'b' * 40)

    def test_required_batches_are_disjoint_and_serial(self):
        for batch in ['core', 'ui']:
            command = watchdog.command(batch, '/Applications/Xcode.app/Contents/Developer')
            self.assertIn('--no-parallel', command)
            self.assertIn('--skip-build', command)
            self.assertEqual(command[command.index('--jobs') + 1], '1')
        core = watchdog.command('core', '/Xcode')[-1]
        ui = watchdog.command('ui', '/Xcode')[-1]
        self.assertIn('HostLifecycleHarnessTests', core)
        self.assertNotIn('EdithHostUITests', core)
        self.assertEqual(ui, '^EdithHostUITests\\.')
        with self.assertRaises(KeyError):
            watchdog.command('unknown', '/Xcode')

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

    def test_child_count_is_pids_and_reused_generation_is_not_signalled(self):
        ownership = object.__new__(watchdog.OwnedProcesses)
        ownership.leader = 100
        ownership.known = {}
        identities = {100: (100, 1, 1, '/owned/swift'),
                      101: (101, 2, 2, '/owned/swiftpm-testing-helper')}
        ownership.identity = lambda pid: identities.get(pid)
        class Library:
            def proc_listchildpids(self, pid, children, size):
                if pid == 100:
                    children[0] = 101
                    return 1
                return 0
        ownership.library = Library()
        self.assertEqual(len(ownership.refresh()), 2)
        identities[101] = (101, 3, 3, '/owned/swiftpm-testing-helper')
        self.assertEqual(ownership.refresh(), [identities[100]])
        self.assertEqual(ownership.known[101][1], 2)

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
                                json.dumps({'pid': pid, 'procPath': executable}))
            (directory / 'symlink.ips').symlink_to(directory / 'owned.ips')
            retained = watchdog.owned_crash_reports(directory, output, [identity], time.time() - 1)
            self.assertEqual(retained, ['owned-crash-123-0.ips'])
            self.assertIn('bug_type', (output / retained[0]).read_text())
            self.assertEqual(watchdog.owned_crash_reports(directory, output, [identity], time.time() + 1), [])

    def test_public_process_structure_matches_sdk_layout(self):
        self.assertEqual(watchdog.ctypes.sizeof(watchdog.ProcessInfo), 136)


if __name__ == '__main__':
    unittest.main()
