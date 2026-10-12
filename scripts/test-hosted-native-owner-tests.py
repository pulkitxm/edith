from pathlib import Path
import importlib.util
import json
import re
import shlex
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'owner_tests', Path(__file__).with_name('hosted-native-owner-tests.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Clock:
    def __init__(self):
        self.value = 0

    def now(self):
        return self.value

    def sleep(self, value):
        self.value += value


class Process:
    pid = 123

    def __init__(self, exit_code=None):
        self.returncode = exit_code
        self.reaps = 0

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.reaps += 1
        if self.returncode is None:
            raise subprocess.TimeoutExpired('make', timeout)
        return self.returncode


class Ownership:
    def __init__(self, process, survives_term=False, conflicts=False, observes_test=True):
        self.process = process
        self.survives_term = survives_term
        self.identity_value = (234, 100, 7, '/fixture/swiftpm-testing', 123)
        self.active = process.returncode is None
        self.signals = []
        self.has_conflicts = conflicts
        self.observes_test = observes_test
        self.first = True

    def refresh(self):
        if self.first and self.observes_test and self.process.returncode == 0:
            self.first = False
            return [self.identity_value]
        self.first = False
        return [self.identity_value] if self.active else []

    def identity(self, pid):
        return self.identity_value if self.active and pid == 234 else None

    def conflicts(self):
        return [self.identity_value] if self.has_conflicts else []

    def terminate(self, value):
        self.signals.append(value)
        if value == signal.SIGKILL or (value == signal.SIGTERM and not self.survives_term):
            self.active = False
            self.process.returncode = -value


class OriginalNativeOwnerTests(unittest.TestCase):
    def environment(self):
        return {
            'EXPECTED_SOURCE_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40,
            'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
            'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
            'GITHUB_REPOSITORY': 'pulkitxm/edith', 'GITHUB_REPOSITORY_ID': '1289153439',
            'GITHUB_ACTOR_ID': '65671483', 'GITHUB_REF': 'refs/heads/feat/extension-marketplace',
            'EDITH_HOSTED_NATIVE_OWNER_TESTS': '1', 'EDITH_HOSTED_RELEASE': 'false',
            'EDITH_HOSTED_REBUILD': '', 'NATIVE_TEST_OWNER': 'attention',
        }

    def test_exact_source_hosted_admission_accepts_only_fixed_owners(self):
        for owner in runner.TARGETS:
            for actor in ('65671483', '320458784'):
                for ref in ('refs/heads/feat/extension-marketplace', 'refs/heads/main'):
                    environment = dict(self.environment(), NATIVE_TEST_OWNER=owner,
                                       GITHUB_ACTOR_ID=actor, GITHUB_REF=ref)
                    self.assertEqual(runner.admit(environment, 'a' * 40), owner)

    def test_local_self_hosted_other_actor_repo_source_release_and_arbitrary_commands_reject(self):
        invalid = {
            'GITHUB_ACTIONS': 'false', 'RUNNER_OS': 'Linux',
            'RUNNER_ENVIRONMENT': 'self-hosted', 'GITHUB_EVENT_NAME': 'pull_request',
            'GITHUB_REPOSITORY': 'other/edith', 'GITHUB_REPOSITORY_ID': 'other',
            'GITHUB_ACTOR_ID': '999', 'GITHUB_REF': 'refs/pull/1014/merge',
            'EXPECTED_SOURCE_SHA': 'invalid', 'GITHUB_SHA': 'b' * 40,
            'EDITH_HOSTED_NATIVE_OWNER_TESTS': '0', 'EDITH_HOSTED_RELEASE': 'true',
            'EDITH_HOSTED_REBUILD': 'v1', 'NATIVE_TEST_OWNER': 'attention --skip all',
        }
        for key, value in invalid.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.admit(dict(self.environment(), **{key: value}), 'a' * 40)
        with self.assertRaises(ValueError):
            runner.admit(self.environment(), 'b' * 40)

    def test_every_original_make_target_and_prerequisite_is_selected_without_filter_or_skip(self):
        definitions = json.loads((Path(__file__).parent.parent / 'Extensions/manifest.json').read_text())
        expected = {
            'attention': ['make', 'ci-extension-attention'],
            'terminal': ['make', 'ci-extension-terminal'],
            'timeLapse': ['make', 'ci-extension-time-lapse'],
            'studio': ['make', 'ci-extension-studio', 'ci-extension-studio-native'],
            'machines': ['make', 'ci-extension-machines'],
            'virtualCamera': ['make', 'ci-extension-camera', 'ci-extension-camera-carrier', 'ci-extension-camera-voice'],
            'feature-models': ['make', 'ci-extension-support', 'ci-extension-docs'],
        }
        for owner, command in expected.items():
            self.assertEqual(runner.original_command(owner, definitions), command)
        self.assertEqual(runner.TEST_DEADLINE, 40 * 60)

    def test_changed_duplicated_or_missing_manifest_targets_reject(self):
        for definitions in ([], [{'id': 'attention', 'testTargets': []}],
                            [{'id': 'attention', 'testTargets': ['ci-extension-attention']}] * 2):
            with self.assertRaises(ValueError):
                runner.original_command('attention', definitions)

    def test_original_camera_command_enforces_privileged_lockfile_without_skipping_targets(self):
        root = Path(__file__).resolve().parent.parent
        text = (root / 'Makefile').read_text()
        recipe = re.search(r'^ci-extension-camera:\n((?:\t.*\n)+)', text, re.MULTILINE).group(1)
        lines = recipe.splitlines()
        privileged = shlex.split(lines[0].replace('$(EXTENSION_SWIFT_JOBS)', '1'))
        self.assertEqual(privileged, [
            'swift', 'test', '--package-path', 'Extensions/virtualCamera/Privileged',
            '--build-system', 'native', '--jobs', '1', '--no-parallel', '--force-resolved-versions'])
        self.assertEqual(lines[1].strip(), '$(call UTILITY_EXTENSION_NATIVE_TEST,virtualCamera)')
        self.assertTrue(lines[2].strip().startswith('swiftc -typecheck '))
        definitions = json.loads((root / 'Extensions/manifest.json').read_text())
        self.assertEqual(runner.original_command('virtualCamera', definitions), [
            'make', 'ci-extension-camera', 'ci-extension-camera-carrier', 'ci-extension-camera-voice'])

    def run_fixture(self, text, process, ownership, sample=None):
        clock = Clock()
        with tempfile.TemporaryDirectory() as fixture:
            output = Path(fixture)

            def launch(arguments, **kwargs):
                self.assertTrue(kwargs['start_new_session'])
                self.assertEqual(arguments, ['make', 'ci-extension-attention'])
                kwargs['stdout'].write(text.encode())
                kwargs['stdout'].flush()
                return process

            with patch.object(runner.watchdog, 'owned_crash_reports', return_value=[]):
                result = runner.run_original(
                    ['make', 'ci-extension-attention'], output, {}, output, deadline=1,
                    process_factory=launch, ownership_factory=lambda pid, uid: ownership,
                    clock=clock.now, sleep=clock.sleep, sample=sample or (lambda *args, **kwargs: None))
            return result, (output / 'tests.log').read_text(), (output / 'processes.jsonl').read_text()

    def test_success_requires_real_nonempty_completion_and_natural_retirement(self):
        process = Process(0)
        result, text, timeline = self.run_fixture('Test run with 19 tests in 4 suites passed.\n', process, Ownership(process))
        self.assertTrue(result['passed'])
        self.assertTrue(result['testsCompleted'])
        self.assertEqual(result['exitCode'], 0)
        self.assertEqual(process.reaps, 1)
        self.assertIn('parentExitCode', timeline)
        self.assertEqual(len(result['logSHA256']), 64)

    def test_clean_wrapper_exit_without_observed_native_testing_process_fails(self):
        process = Process(0)
        result, _, _ = self.run_fixture(
            'Test run with 19 tests in 4 suites passed.\n', process,
            Ownership(process, observes_test=False))
        self.assertFalse(result['passed'])
        self.assertFalse(result['observedTestingProcess'])

    def test_empty_or_failed_native_output_cannot_be_reported_as_pass(self):
        for text, code in (('Build complete!\n', 0), ('Test run with 0 tests passed.\n', 0),
                           ('Executed 2 tests, with 1 failure.\n', 0),
                           ('Test run with 19 tests passed.\n', 1)):
            process = Process(code)
            result, _, _ = self.run_fixture(text, process, Ownership(process))
            self.assertFalse(result['passed'])
            self.assertEqual(result['exitCode'], code)

    def test_startup_hang_retains_owned_testing_identity_sample_and_original_deadline(self):
        process = Process()
        ownership = Ownership(process, survives_term=True)
        samples = []
        def sample(*args, **kwargs):
            self.assertEqual(ownership.signals, [signal.SIGSTOP])
            samples.append(args[0])
        result, text, timeline = self.run_fixture(
            'Build complete!\n', process, ownership, sample)
        self.assertFalse(result['passed'])
        self.assertTrue(result['timedOut'])
        self.assertEqual(result['exitCode'], 124)
        self.assertTrue(result['observedTestingProcess'])
        self.assertIn('/fixture/swiftpm-testing', timeline)
        self.assertEqual(samples[0][:3], ['/usr/bin/sample', '234', '3'])
        self.assertEqual(ownership.signals, [signal.SIGSTOP, signal.SIGTERM, signal.SIGKILL])
        self.assertTrue(result['cleanup']['reaped'])
        self.assertEqual(result['cleanup']['remainingOwnedProcesses'], 0)
        self.assertEqual(text, 'Build complete!\n')

    def test_owned_descendant_remaining_after_parent_exit_is_cleaned_but_never_passes(self):
        process = Process(0)
        ownership = Ownership(process, survives_term=True)
        ownership.active = True
        result, _, _ = self.run_fixture('Test run with 19 tests passed.\n', process, ownership)
        self.assertFalse(result['passed'])
        self.assertEqual(result['cleanup']['naturalSurvivorCount'], 1)
        self.assertEqual(ownership.signals, [signal.SIGTERM, signal.SIGKILL])

    def test_identity_conflict_is_not_claimed_as_retired(self):
        process = Process(0)
        result, _, _ = self.run_fixture('Test run with 19 tests passed.\n', process, Ownership(process, conflicts=True))
        self.assertFalse(result['passed'])
        self.assertEqual(result['cleanup']['unverifiedOwnedProcesses'], 1)

    def test_ownership_enumeration_failure_retains_verified_identities_and_fails(self):
        process = Process(0)
        ownership = Ownership(process)
        ownership.errors = ['Owned descendant bound exceeded']
        result, _, _ = self.run_fixture('Test run with 19 tests passed.\n', process, ownership)
        self.assertFalse(result['passed'])
        self.assertEqual(result['cleanup']['ownershipErrors'], ownership.errors)

    def test_ownership_startup_failure_kills_unreaped_session_then_reaps(self):
        process = Process(0)
        with tempfile.TemporaryDirectory() as fixture:
            output = Path(fixture)
            with patch.object(runner.os, 'getpgid', return_value=123), \
                    patch.object(runner.os, 'killpg') as kill:
                with self.assertRaisesRegex(OSError, 'ownership unavailable'):
                    runner.run_original(
                        ['make', 'ci-extension-attention'], output, {}, output,
                        process_factory=lambda *args, **kwargs: process,
                        ownership_factory=lambda *args: (_ for _ in ()).throw(OSError('ownership unavailable')))
                self.assertEqual(kill.call_args_list, [
                    unittest.mock.call(123, signal.SIGTERM), unittest.mock.call(123, signal.SIGKILL)])
                self.assertEqual(process.reaps, 1)


class Kernel:
    def __init__(self):
        self.processes = {123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)}
        self.signals = []

    def proc_pidinfo(self, pid, flavor, argument, pointer, size):
        value = self.processes.get(pid)
        if value is None:
            return 0
        info = pointer._obj
        info.pid, info.seconds, info.microseconds = value[:3]
        info.pgid, info.ppid, info.uid, info.ruid = value[4:]
        return size

    def proc_pidpath(self, pid, buffer, size):
        value = self.processes.get(pid)
        if value is None:
            return 0
        buffer.value = value[3].encode()
        return len(buffer.value)

    def proc_listchildpids(self, pid, children, size):
        values = [item[0] for item in self.processes.values() if item[5] == pid]
        for index, child in enumerate(values[:64]):
            children[index] = child
        return len(values)

    def kill(self, pid, value):
        if pid not in self.processes:
            raise ProcessLookupError()
        if value:
            self.signals.append((pid, value))


class OwnedKernelContracts(unittest.TestCase):
    def setUp(self):
        self.kernel = Kernel()
        self.library = patch.object(runner.watchdog.ctypes, 'CDLL', return_value=self.kernel)
        self.kill = patch.object(runner.os, 'kill', side_effect=self.kernel.kill)
        self.library.start()
        self.kill.start()
        self.addCleanup(self.library.stop)
        self.addCleanup(self.kill.stop)
        self.owner = runner.BoundedOwnership(123, 501)

    def test_live_exec_transition_retains_root_and_discovers_original_native_child(self):
        self.owner.refresh()
        self.kernel.processes[123] = (123, 100, 7, '/fixture/Xcode/usr/bin/make', 123, 1, 501, 501)
        self.kernel.processes[234] = (234, 101, 8, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)
        self.assertEqual({item[0] for item in self.owner.refresh()}, {123, 234})
        self.assertEqual(self.owner.transitions[0]['previous'][3], '/usr/bin/make')
        self.assertEqual(self.owner.transitions[0]['current'][3], '/fixture/Xcode/usr/bin/make')
        self.owner.terminate(signal.SIGSTOP)
        self.assertEqual(set(self.kernel.signals), {(123, signal.SIGSTOP), (234, signal.SIGSTOP)})
        self.assertEqual(self.owner.errors, [])

    def test_original_deadline_stops_transitioned_root_and_native_child_before_sampling(self):
        process = Process()
        self.owner.refresh()
        self.kernel.processes[123] = (123, 100, 7, '/fixture/Xcode/usr/bin/make', 123, 1, 501, 501)
        self.kernel.processes[234] = (234, 101, 8, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)
        samples = []
        original = self.kernel.kill

        def kill(pid, value):
            original(pid, value)
            if value == signal.SIGKILL:
                self.kernel.processes.pop(pid)
                if pid == process.pid:
                    process.returncode = -value

        self.kill.stop()
        with patch.object(runner.os, 'kill', side_effect=kill):
            result, _, _ = OriginalNativeOwnerTests.run_fixture(
                self, 'Build complete!\n', process, self.owner,
                lambda *args, **kwargs: samples.append((args[0], list(self.kernel.signals))))
        self.assertTrue(result['timedOut'])
        self.assertEqual(result['exitCode'], 124)
        self.assertTrue(result['observedTestingProcess'])
        self.assertEqual(samples[0][0][1], '234')
        self.assertEqual(set(samples[0][1]), {(123, signal.SIGSTOP), (234, signal.SIGSTOP)})
        self.assertEqual(result['cleanup']['remainingOwnedProcesses'], 0)
        self.assertTrue(result['cleanup']['reaped'])

    def test_reused_pid_birth_uid_real_uid_and_group_cannot_renew_ownership(self):
        for index, value in [(1, 200), (2, 9), (4, 456), (6, 502), (7, 502)]:
            with self.subTest(index=index):
                self.kernel.processes[123] = (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                owner.refresh()
                changed = list(self.kernel.processes[123])
                changed[index] = value
                self.kernel.processes[123] = tuple(changed)
                self.kernel.signals.clear()
                owner.terminate(signal.SIGKILL)
                self.assertEqual(self.kernel.signals, [])
                self.assertTrue(owner.errors)

    def test_identity_is_rechecked_immediately_before_signal(self):
        self.owner.refresh()
        original = self.owner.refresh

        def race():
            values = original()
            self.kernel.processes[123] = (123, 200, 7, '/usr/bin/make', 123, 1, 501, 501)
            return values

        self.owner.refresh = race
        self.owner.terminate(signal.SIGTERM)
        self.assertEqual(self.kernel.signals, [])

    def test_parent_pid_reuse_during_child_enumeration_never_admits_or_signals_foreign_child(self):
        original = self.kernel.proc_listchildpids

        def enumerate_children(pid, children, size):
            if pid == 123:
                self.kernel.processes[123] = (123, 200, 7, '/fixture/foreign-parent', 123, 1, 501, 501)
                self.kernel.processes[234] = (234, 201, 8, '/fixture/foreign-child', 123, 123, 501, 501)
            return original(pid, children, size)

        self.kernel.proc_listchildpids = enumerate_children
        self.owner.refresh()
        self.assertNotIn(234, self.owner.seals)
        self.assertNotIn(234, self.owner.known)
        self.assertIn('Owned parent identity changed before admission', self.owner.errors)
        self.owner.terminate(signal.SIGKILL)
        self.assertEqual(self.kernel.signals, [])

    def test_verified_dead_history_does_not_consume_concurrent_bound_or_allow_pid_reuse(self):
        self.owner.refresh()
        for pid in range(200, 300):
            self.kernel.processes[pid] = (pid, pid, 7, '/fixture/compiler', 123, 123, 501, 501)
            self.assertEqual(len(self.owner.refresh()), 2)
            del self.kernel.processes[pid]
            self.assertEqual(len(self.owner.refresh()), 1)
        self.assertEqual(len(self.owner.seals), 101)
        self.assertEqual(len(self.owner.known), 1)
        self.assertEqual(self.owner.errors, [])
        self.kernel.processes[200] = (200, 400, 7, '/fixture/compiler', 123, 123, 501, 501)
        self.owner.refresh()
        self.assertTrue(self.owner.errors)

    def test_concurrent_process_and_lifetime_transition_bounds_fail_closed(self):
        for pid in range(200, 264):
            self.kernel.processes[pid] = (pid, pid, 7, '/fixture/compiler', 123, 123, 501, 501)
        self.owner.refresh()
        self.assertTrue(self.owner.errors)
        self.kernel.processes = {123: self.kernel.processes[123]}
        owner = runner.BoundedOwnership(123, 501)
        owner.refresh()
        owner.transitions = [{}] * 1024
        self.kernel.processes[123] = (123, 100, 7, '/fixture/other-make', 123, 1, 501, 501)
        owner.refresh()
        self.assertIn('Owned executable transition bound exceeded', owner.errors)
        owner = runner.BoundedOwnership(123, 501)
        owner.seals = {pid: (pid, 1, 1, 123) for pid in range(5000, 9096)}
        owner.refresh()
        self.assertIn('Owned lifetime process bound exceeded', owner.errors)


if __name__ == '__main__':
    unittest.main()
