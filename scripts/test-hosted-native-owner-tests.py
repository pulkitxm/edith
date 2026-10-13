from pathlib import Path
import importlib.util
import ctypes
import json
import os
import re
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from unittest.mock import Mock


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

    def run_fixture(self, text, process, ownership, sample=None, selection=None):
        clock = Clock()
        command = ['make', *runner.TARGETS[selection]] if selection else ['make', 'ci-extension-attention']
        with tempfile.TemporaryDirectory() as fixture:
            output = Path(fixture)

            def launch(arguments, **kwargs):
                self.assertTrue(kwargs['start_new_session'])
                self.assertEqual(arguments, command)
                kwargs['stdout'].write(text.encode())
                kwargs['stdout'].flush()
                return process

            with patch.object(runner.watchdog, 'owned_crash_reports', return_value=[]):
                result = runner.run_original(
                    command, output, {}, output, deadline=1,
                    process_factory=launch, ownership_factory=lambda pid, uid: ownership,
                    clock=clock.now, sleep=clock.sleep, sample=sample or (lambda *args, **kwargs: None),
                    selection=selection)
            return result, (output / 'tests.log').read_text(), (output / 'processes.jsonl').read_text()

    def database_log(self, method='mutationPreviewNormalizesWithoutExecuting'):
        return ('◇ Suite DatabaseExecutorTests started.\n'
                f'◇ Test {method}() started.\n'
                f'✔ Test {method}() passed after 0.001 seconds.\n'
                '✔ Suite DatabaseExecutorTests passed after 0.002 seconds.\n'
                '✔ Test run with 1 test in 1 suite passed after 0.003 seconds.\n')

    def test_database_diagnostics_keep_the_original_manifest_contract(self):
        definitions = [{'id': 'database', 'testTargets': ['ci-extension-database']}]
        for owner in runner.DATABASE_DIAGNOSTICS:
            self.assertEqual(runner.original_command(owner, definitions), ['make', *runner.TARGETS[owner]])
            for invalid in ([], definitions * 2,
                            [{'id': owner, 'testTargets': runner.TARGETS[owner]}],
                            [{'id': 'database', 'testTargets': runner.TARGETS[owner]}]):
                with self.subTest(owner=owner, invalid=invalid), self.assertRaises(ValueError):
                    runner.original_command(owner, invalid)

    def test_database_recipes_have_fixed_filters_jobs_and_resource_profiles(self):
        root = Path(__file__).parent.parent
        source = (root / 'Makefile').read_text()
        gate_spec = importlib.util.spec_from_file_location('database_gate', root / 'scripts/make-resource-gate.py')
        gate = importlib.util.module_from_spec(gate_spec)
        gate_spec.loader.exec_module(gate)
        for suffix, selected in [('mutation', 'mutationPreviewNormalizesWithoutExecuting'),
                                 ('executor', 'DatabaseExecutorTests')]:
            target = 'ci-extension-database-' + suffix
            recipe = re.search(r'^' + target + r':\n((?:\t.*\n)+)', source, re.MULTILINE).group(1)
            self.assertEqual(shlex.split(recipe), [
                'env', '-u', 'EDITH_DATABASE_POSTGRESQL_HOST', 'swift', 'test', '--package-path',
                'Extensions/database/DatabaseEngine', '--no-parallel', '--jobs', '1', '--filter', selected])
            self.assertEqual(gate.profile_for(target), gate.PROFILES['swift-test'])
        original = re.search(r'^ci-extension-database:\n((?:\t.*\n)+)', source, re.MULTILINE).group(1)
        self.assertEqual(original, '\tswift format lint --strict --recursive Extensions/database\n'
                         '\tenv -u EDITH_DATABASE_POSTGRESQL_HOST swift test --package-path Extensions/database/DatabaseEngine --no-parallel --jobs $(EXTENSION_SWIFT_JOBS)\n'
                         "\tcd Extensions/database && env -u EDITH_DATABASE_POSTGRESQL_HOST EDITH_DATABASE_RELATION_FILTERS=0 node test.mjs $(if $(FILTER),'$(FILTER)')\n")

    def test_database_mutation_requires_its_exact_started_passed_and_summary_rows(self):
        text = self.database_log()
        self.assertTrue(runner.database_completed(text, 'database-mutation'))
        invalid = [
            text.replace('mutationPreviewNormalizesWithoutExecuting', 'differentMethod'),
            text.replace('DatabaseExecutorTests', 'DifferentSuite'),
            text.replace('1 test in 1 suite', '0 tests in 0 suites'),
            text.replace('◇ Test mutationPreviewNormalizesWithoutExecuting() started.\n', ''),
            text.replace('✔ Suite DatabaseExecutorTests passed after 0.002 seconds.\n', ''),
            text.replace('◇ Suite DatabaseExecutorTests started.\n', ''),
            text + '✘ Test differentMethod() failed after 0.001 seconds.\n',
            text.replace('1 test in 1 suite', '2 tests in 1 suite'),
            text.replace('✔ Test run', 'synthetic message: ✔ Test run'),
        ]
        for value in invalid:
            with self.subTest(text=value):
                self.assertFalse(runner.database_completed(value, 'database-mutation'))
        with self.assertRaises(ValueError):
            runner.database_completed(text, 'database --filter arbitrary')

    def test_database_suite_requires_selected_suite_completion_not_an_unrelated_pass(self):
        text = self.database_log('mutationPreviewRejectsAPlanForADifferentRequest')
        self.assertTrue(runner.database_completed(text, 'database-executor'))
        parameterized = text.replace('() passed after', '(value:) with 2 test cases passed after')
        self.assertTrue(runner.database_completed(parameterized, 'database-executor'))
        for value in [text.replace('✔ Suite DatabaseExecutorTests passed after 0.002 seconds.', ''),
                      text.replace('✔ Test mutationPreviewRejectsAPlanForADifferentRequest() passed after 0.001 seconds.', ''),
                      text.replace('◇ Test mutationPreviewRejectsAPlanForADifferentRequest() started.', ''),
                      text.replace('DatabaseExecutorTests', 'UnrelatedTests')]:
            self.assertFalse(runner.database_completed(value, 'database-executor'))

    def test_database_runtime_zero_match_and_faked_rows_fail_closed_with_clean_ownership(self):
        for text in ['Test run with 0 tests passed.\n',
                     'Test run with 1 test passed.\n',
                     self.database_log('unrelatedMethod')]:
            process = Process(0)
            result, _, _ = self.run_fixture(text, process, Ownership(process), selection='database-mutation')
            self.assertFalse(result['passed'])
            self.assertFalse(result['testsCompleted'])
            self.assertEqual(result['exitCode'], 0)
            self.assertEqual(result['cleanup']['remainingOwnedProcesses'], 0)
        process = Process(0)
        result, _, _ = self.run_fixture(self.database_log(), process, Ownership(process), selection='database-mutation')
        self.assertTrue(result['passed'])
        self.assertTrue(result['testsCompleted'])

    def test_unknown_database_selection_rejects_before_any_process_launch(self):
        with self.assertRaises(ValueError):
            runner.run_original([], Path('/synthetic'), {}, Path('/synthetic'),
                                selection='database-arbitrary',
                                process_factory=lambda *args, **kwargs: self.fail('Unexpected process launch'))

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

    def test_failure_observations_are_retained_without_changing_failed_outcome(self):
        process = Process(0)
        ownership = Ownership(process, conflicts=True)
        observation = {'kind': 'live_identity_unavailable', 'returnedBytes': 0, 'status': None}
        ownership.failure_observations = [observation]
        result, _, _ = self.run_fixture('Test run with 19 tests passed.\n', process, ownership)
        self.assertFalse(result['passed'])
        self.assertEqual(result['ownershipFailureObservations'], [observation])
        self.assertEqual(result['cleanup']['unverifiedOwnedProcesses'], 1)

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

    def add_path_gap(self, pid=234):
        self.kernel.processes[pid] = (pid, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        original_path = self.kernel.proc_pidpath
        original_info = self.kernel.proc_pidinfo
        def path(child, buffer, size):
            return 0 if child == pid else original_path(child, buffer, size)
        def info(child, flavor, argument, pointer, size):
            result = original_info(child, flavor, argument, pointer, size)
            if child == pid:
                pointer._obj.status = 2
            return result
        return path, info

    def test_path_gap_remains_unverified_until_exact_same_birth_full_identity_recovers(self):
        path, info = self.add_path_gap()
        with patch.object(self.kernel, 'proc_pidpath', side_effect=path), \
                patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
            for _ in range(2):
                self.assertEqual({item[0] for item in self.owner.refresh()}, {123})
                self.assertNotIn(234, self.owner.known)
                self.assertEqual(len(self.owner.conflicts()), 1)
                self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.kernel.signals, [])
        self.owner.refresh()
        self.assertIn(234, self.owner.known)
        self.assertEqual(self.owner.pending, {})
        self.assertEqual(self.owner.conflicts(), [])
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.failure_observations[0]['kind'], 'pending_executable_identity')

    def test_retirement_uses_final_pending_resolution_and_retains_permanent_rejections(self):
        for resolves in (False, True):
            with self.subTest(resolves=resolves):
                owner = unittest.mock.Mock()
                unresolved = [123]
                owner.errors = ['permanent ownership rejection']
                calls = 0
                def refresh():
                    nonlocal calls
                    calls += 1
                    if resolves and calls >= 2:
                        unresolved.clear()
                    return []
                owner.refresh.side_effect = refresh
                owner.conflicts.side_effect = lambda: list(unresolved)
                clock = Clock()
                result = runner.retire(Process(0), owner, clock.now, clock.sleep)
                self.assertEqual(result['unverifiedOwnedProcesses'], 0 if resolves else 1)
                self.assertEqual(result['ownershipErrors'], ['permanent ownership rejection'])
                self.assertEqual(clock.value, 0)
                owner.terminate.assert_not_called()

    def test_unresolved_path_gap_cannot_turn_clean_exit_and_real_test_completion_into_pass(self):
        path, info = self.add_path_gap()
        self.kernel.processes[345] = (345, 102, 9, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)
        original_refresh = self.owner.refresh
        first = True
        def refresh():
            nonlocal first
            rows = original_refresh()
            if first:
                first = False
                del self.kernel.processes[345]
                del self.kernel.processes[123]
            return rows
        with patch.object(self.kernel, 'proc_pidpath', side_effect=path), \
                patch.object(self.kernel, 'proc_pidinfo', side_effect=info), \
                patch.object(self.owner, 'refresh', side_effect=refresh):
            result, _, _ = OriginalNativeOwnerTests.run_fixture(
                self, 'Test run with 1 test passed.\n', Process(0), self.owner)
        self.assertFalse(result['passed'])
        self.assertTrue(result['testsCompleted'])
        self.assertTrue(result['observedTestingProcess'])
        self.assertEqual(result['pendingOwnedIdentityCount'], 1)
        self.assertEqual(result['cleanup']['unverifiedOwnedProcesses'], 1)
        self.assertNotIn((234, signal.SIGTERM), self.kernel.signals)
        self.assertNotIn((234, signal.SIGKILL), self.kernel.signals)

    def test_quarantined_child_birth_or_uid_change_never_admits_or_signals_reused_pid(self):
        for index, value in [(1, 200), (2, 99), (6, 502), (7, 502)]:
            with self.subTest(index=index):
                self.kernel.processes = {123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)}
                owner = runner.BoundedOwnership(123, 501)
                path, info = self.add_path_gap()
                with patch.object(self.kernel, 'proc_pidpath', side_effect=path), \
                        patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
                    owner.refresh()
                changed = list(self.kernel.processes[234])
                changed[index] = value
                self.kernel.processes[234] = tuple(changed)
                owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.known)
                owner.terminate(signal.SIGKILL)
                self.assertNotIn((234, signal.SIGKILL), self.kernel.signals)

    def test_pending_child_terminal_or_gone_retires_without_becoming_testing_or_signal_authority(self):
        for terminal in (False, True):
            with self.subTest(terminal=terminal):
                self.kernel.processes = {123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)}
                owner = runner.BoundedOwnership(123, 501)
                path, info = self.add_path_gap()
                with patch.object(self.kernel, 'proc_pidpath', side_effect=path), \
                        patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
                    owner.refresh()
                if not terminal:
                    del self.kernel.processes[234]
                    owner.refresh()
                else:
                    original = self.kernel.proc_pidinfo
                    def zombie(pid, flavor, argument, pointer, size):
                        result = original(pid, flavor, argument, pointer, size)
                        if pid == 234:
                            pointer._obj.status = 5
                        return result
                    with patch.object(self.kernel, 'proc_pidpath', side_effect=path), \
                            patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
                        owner.refresh()
                self.assertEqual(owner.pending, {})
                self.assertEqual(owner.errors, [])
                self.assertNotIn(234, owner.known)
                self.assertEqual(self.kernel.signals, [])

    def test_new_terminal_child_foreign_parent_or_unstable_birth_remains_failure(self):
        for failure in ('foreign-parent', 'birth-change', 'parent-change'):
            with self.subTest(failure=failure):
                self.kernel.processes = {123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501),
                                         234: (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)}
                owner = runner.BoundedOwnership(123, 501)
                original = self.kernel.proc_pidinfo
                calls = 0
                def zombie(pid, flavor, argument, pointer, size):
                    nonlocal calls
                    if pid == 234 and argument == 0:
                        return 0
                    result = original(pid, flavor, argument, pointer, size)
                    if pid == 234:
                        calls += 1
                        pointer._obj.status = 5
                        if failure == 'foreign-parent':
                            pointer._obj.ppid = 999
                        if failure == 'birth-change' and calls == 2:
                            pointer._obj.microseconds = 9
                        if failure == 'parent-change' and calls == 2:
                            self.kernel.processes[123] = (123, 200, 7, '/fixture/reused', 123, 1, 501, 501)
                    return result
                with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
                    owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.seals)
                self.assertNotIn(234, owner.known)

    def test_only_same_birth_child_own_group_transition_updates_current_signal_identity(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        self.owner.refresh()
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 234, 123, 501, 501)
        self.owner.refresh()
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.group_transitions, [
            {'previous': (234, 101, 8, 123), 'current': (234, 101, 8, 234)}])
        self.assertEqual(self.owner.known[234][4], 234)
        self.kernel.processes[234] = (234, 200, 8, '/fixture/reused', 234, 123, 501, 501)
        self.owner.terminate(signal.SIGKILL)
        self.assertNotIn((234, signal.SIGKILL), self.kernel.signals)
        self.assertTrue(self.owner.errors)

    def test_foreign_group_changed_leader_or_unstable_transition_never_gains_signal_authority(self):
        for failure in ('foreign-group', 'leader', 'unstable'):
            with self.subTest(failure=failure):
                self.kernel.processes = {123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501),
                                         234: (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)}
                owner = runner.BoundedOwnership(123, 501)
                owner.refresh()
                pid = 123 if failure == 'leader' else 234
                values = list(self.kernel.processes[pid])
                values[4] = 999 if failure != 'unstable' else pid
                self.kernel.processes[pid] = tuple(values)
                original = self.kernel.proc_pidpath
                reads = 0
                def changing(child, buffer, size):
                    nonlocal reads
                    result = original(child, buffer, size)
                    if child == 234:
                        reads += 1
                        if reads == 2:
                            buffer.value = b'/fixture/changed'
                    return result
                with patch.object(self.kernel, 'proc_pidpath', side_effect=changing):
                    owner.refresh()
                self.assertTrue(owner.errors)
                self.assertEqual(owner.group_transitions, [])

    def test_sealed_zombie_retires_without_signals_and_retains_birth_history(self):
        self.owner.refresh()
        seal = self.owner.seals[123]
        original = self.kernel.proc_pidinfo

        def zombie(pid, flavor, argument, pointer, size):
            if argument == 0:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 5
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
            self.assertEqual(self.owner.refresh(), [])
            self.assertEqual(self.owner.refresh(), [])
            self.owner.terminate(signal.SIGTERM)
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.conflicts(), [])
        self.assertNotIn(123, self.owner.known)
        self.assertEqual(self.owner.seals[123], seal)
        self.assertEqual(self.kernel.signals, [])
        self.assertEqual(self.owner.failure_observations, [])
        self.kernel.processes[123] = (123, 200, 7, '/fixture/reused', 123, 1, 501, 501)
        self.owner.refresh()
        self.assertEqual(self.owner.seals[123], seal)
        self.assertTrue(self.owner.errors)
        self.assertNotIn(123, self.owner.known)

    def test_incomplete_live_or_mismatched_zombie_probe_remains_rejected(self):
        for field, changed in [('status', 2), ('pid', 124), ('seconds', 200),
                               ('microseconds', 9), ('pgid', 456), ('uid', 502),
                               ('ruid', 502), ('short', 135), ('error', None)]:
            with self.subTest(field=field):
                owner = runner.BoundedOwnership(123, 501)
                original = self.kernel.proc_pidinfo

                def probe(pid, flavor, argument, pointer, size):
                    if argument == 0:
                        return 0
                    result = original(pid, flavor, argument, pointer, size)
                    pointer._obj.status = 5
                    if field == 'error':
                        raise OSError('synthetic probe failure')
                    if field == 'short':
                        return changed
                    setattr(pointer._obj, field, changed)
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe):
                    self.assertEqual(owner.refresh(), [])
                    owner.terminate(signal.SIGKILL)
                self.assertTrue(owner.errors)
                self.assertEqual(len(owner.conflicts()), 1)
                self.assertIn(123, owner.known)
                self.assertEqual(self.kernel.signals, [])

    def test_twice_verified_terminal_child_retires_with_owned_parent_without_signal_authority(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        original = self.kernel.proc_pidinfo

        def zombie(pid, flavor, argument, pointer, size):
            if pid == 234 and argument == 0:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            if pid == 234:
                pointer._obj.status = 5
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
            self.assertEqual({item[0] for item in self.owner.refresh()}, {123})
        self.assertEqual(self.owner.seals[234], (234, 101, 8, 123))
        self.assertNotIn(234, self.owner.known)
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.terminal_descendants, {234})
        self.assertEqual(self.owner.failure_observations, [])
        self.assertEqual(self.kernel.signals, [])

    def test_later_zombie_proof_does_not_clear_an_existing_ownership_failure(self):
        original = self.kernel.proc_pidinfo
        status = 2

        def probe(pid, flavor, argument, pointer, size):
            if argument == 0:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = status
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe):
            self.assertEqual(self.owner.refresh(), [])
            status = 5
            self.assertEqual(self.owner.refresh(), [])
        self.assertEqual(self.owner.errors, ['Live owned process identity unavailable'])
        self.assertEqual(len(self.owner.conflicts()), 1)
        self.assertEqual(self.kernel.signals, [])

    def test_sealed_zombie_cleanup_preserves_real_test_completion_and_exit_outcome(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)
        for text, code, expected in [
                ('Test run with 19 tests in 4 suites passed.\n', 0, True),
                ('Test run with 29 tests in 7 suites failed with 1 issue.\n', 2, False)]:
            with self.subTest(code=code):
                owner = runner.BoundedOwnership(123, 501)
                original = self.kernel.proc_pidinfo
                original_refresh = owner.refresh
                finished = False

                def probe(pid, flavor, argument, pointer, size):
                    if finished and argument == 0:
                        return 0
                    result = original(pid, flavor, argument, pointer, size)
                    if finished:
                        pointer._obj.status = 5
                    return result

                def refresh():
                    nonlocal finished
                    rows = original_refresh()
                    finished = True
                    return rows

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe), \
                        patch.object(owner, 'refresh', side_effect=refresh):
                    result, _, _ = OriginalNativeOwnerTests.run_fixture(
                        self, text, Process(code), owner)
                self.assertIs(result['passed'], expected)
                self.assertIs(result['testsCompleted'], expected)
                self.assertTrue(result['observedTestingProcess'])
                self.assertEqual(result['exitCode'], code)
                self.assertEqual(result['cleanup']['naturalSurvivorCount'], 0)
                self.assertEqual(result['cleanup']['remainingOwnedProcesses'], 0)
                self.assertEqual(result['cleanup']['unverifiedOwnedProcesses'], 0)
                self.assertEqual(result['cleanup']['ownershipErrors'], [])
                self.assertEqual(self.kernel.signals, [])

    def test_diagnostic_birth_group_and_uid_mismatches_never_change_rejection(self):
        for index, changed, field in [(1, 200, 'birthMatches'), (2, 9, 'birthMatches'),
                                      (4, 456, 'groupMatches'), (6, 502, 'uidMatches'),
                                      (7, 502, 'realUIDMatches')]:
            with self.subTest(field=field, index=index):
                self.kernel.processes[123] = (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                current = list(self.kernel.processes[123])
                current[index] = changed
                self.kernel.processes[123] = tuple(current)
                self.kernel.signals.clear()
                original = self.kernel.proc_pidinfo

                def zombie(pid, flavor, argument, pointer, size):
                    result = original(pid, flavor, argument, pointer, size)
                    if argument == 1:
                        pointer._obj.status = 5
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
                    owner.terminate(signal.SIGKILL)
                self.assertEqual(self.kernel.signals, [])
                self.assertTrue(owner.errors)
                self.assertEqual(len(owner.conflicts()), 1)
                row = owner.failure_observations[0]
                self.assertIs(row[field], False)
                self.assertEqual(row['status'], 5)
                if index in [1, 2, 4]:
                    self.assertEqual(row['kind'], 'birth_or_group_changed')
                    self.assertIs(row['originalBirthMatches'], index == 4)
                    self.assertIs(row['originalGroupMatches'], index != 4)

    def test_unknown_zombie_and_probe_errors_cannot_admit_or_retire_a_process(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        original = self.kernel.proc_pidinfo

        def zombie(pid, flavor, argument, pointer, size):
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 5
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
            self.owner.observe_failure(234, 'live_identity_unavailable')
        row = self.owner.failure_observations[0]
        self.assertIs(row['knownSeal'], False)
        self.assertIsNone(row['birthMatches'])
        self.assertIsNone(row['groupMatches'])
        self.assertEqual(row['status'], 5)
        self.assertNotIn(234, self.owner.known)
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=OSError('private error')):
            self.owner.observe_failure(123, 'live_identity_unavailable')
        self.assertIs(self.owner.failure_observations[1]['probeFailed'], True)
        self.assertIsNone(self.owner.failure_observations[1]['returnedBytes'])
        self.assertNotIn('private', json.dumps(self.owner.failure_observations))
        self.assertEqual(self.kernel.signals, [])
        self.assertEqual(self.owner.errors, [])

    def test_failure_observations_are_bounded_and_short_reads_remain_unqualified(self):
        for pid in range(1000, 1012):
            self.owner.observe_failure(pid, 'live_identity_unavailable')
        self.assertEqual(len(self.owner.failure_observations), 8)
        for row in self.owner.failure_observations:
            self.assertEqual(row['returnedBytes'], 0)
            self.assertIsNone(row['status'])
            self.assertIsNone(row['birthMatches'])
        self.assertEqual(self.kernel.signals, [])
        self.assertEqual(set(self.owner.known), {123})

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


class SelectedDatabaseCaptureContracts(unittest.TestCase):
    def contract(self):
        capture = runner.database_capture
        with patch.object(capture.watchdog, 'canonical_path', side_effect=lambda path, **kwargs: Path(path)), \
                patch.object(capture.driver_runtime, 'SelectedSwiftDriver'), \
                patch.object(capture.watchdog, 'runtime_contract', return_value=(
                    Path('/fixture/toolchain/swiftpm-testing-helper'),
                    Path('/fixture/package/.build/debug/DatabaseEnginePackageTests.xctest'),
                    Path('/fixture/package/.build/debug/DatabaseEnginePackageTests.xctest/Contents/MacOS/DatabaseEnginePackageTests'),
                    {'HOME': '/fixture/home', 'EDITH_DATABASE_POSTGRESQL_HOST': 'ambient.invalid'})), \
                patch.object(capture, 'file_seal', return_value=((1, 2), 'a' * 64)):
            return capture.DatabaseTestContract(
                '/fixture', '/fixture/developer', '/fixture/bin', {},
                'database-mutation', time.monotonic() + 60)

    def owner(self, contract):
        identity = (123, 100, 7, str(contract.helper), 123)
        owner = Mock()
        owner.known = {123: identity}
        owner.verified.return_value = True
        def stopped(pid, flavor, argument, pointer, size):
            info = pointer._obj
            info.pid, info.seconds, info.microseconds, info.pgid = 123, 100, 7, 123
            info.ppid = os.getpid()
            info.status = 4
            info.uid = info.ruid = os.getuid()
            return size
        owner.library.proc_pidinfo.side_effect = stopped
        return owner, identity

    def test_exact_fixed_helper_bundle_filter_and_isolated_environment(self):
        contract = self.contract()
        self.assertEqual(contract.arguments, [
            str(contract.helper), '--test-bundle-path', str(contract.image), '--no-parallel',
            '--filter', 'mutationPreviewNormalizesWithoutExecuting',
            '--testing-library', 'swift-testing'])
        self.assertNotIn('EDITH_DATABASE_POSTGRESQL_HOST', contract.environment)
        self.assertFalse(runner.testing_process('/fixture/swiftpm-xctest-helper'))
        with self.assertRaises(ValueError):
            runner.watchdog.runtime_contract('/nonexistent', '/nonexistent', '/nonexistent', {},
                                            bundle_name='ForeignPackageTests')

    def test_current_private_native_image_seal_rejects_replacement_links_and_mutation(self):
        with tempfile.TemporaryDirectory() as fixture:
            image = Path(fixture).resolve() / 'image'
            image.write_bytes(b'original synthetic image')
            image.chmod(0o700)
            before = runner.database_capture.file_seal(image)
            image.write_bytes(b'changed synthetic image')
            self.assertNotEqual(runner.database_capture.file_seal(image), before)
            link = image.with_name('linked-image')
            os.link(image, link)
            with self.assertRaises(ValueError):
                runner.database_capture.file_seal(image)
            link.unlink()
            alias = image.with_name('alias')
            alias.symlink_to(image)
            with self.assertRaises(ValueError):
                runner.database_capture.file_seal(alias)
            for mode, uid in [(0o100722, os.getuid()), (0o100700, os.getuid() + 1),
                              (0o100600, os.getuid())]:
                descriptor_metadata = Mock(st_mode=mode, st_uid=uid, st_nlink=1, st_size=24)
                with self.subTest(mode=mode, uid=uid), \
                        patch.object(runner.database_capture.os, 'fstat', return_value=descriptor_metadata), \
                        self.assertRaises(ValueError):
                    runner.database_capture.file_seal(image)
            image.chmod(0o722)
            with self.assertRaises(ValueError):
                runner.database_capture.file_seal(image)

    def test_swapped_runtime_or_expired_deadline_never_releases_test(self):
        contract = self.contract()
        with patch.object(runner.database_capture.watchdog, 'canonical_path', side_effect=lambda path, **kwargs: Path(path)), \
                patch.object(runner.database_capture, 'file_seal', return_value=((1, 3), 'b' * 64)):
            with self.assertRaisesRegex(ValueError, 'changed after admission'):
                contract.validate()
        contract.deadline = 0
        with self.assertRaises(TimeoutError):
            contract.validate()

    def test_kernel_suspended_child_identity_must_match_every_field_before_continue(self):
        contract = self.contract()
        for field, wrong in [('pid', 124), ('seconds', 101), ('microseconds', 8),
                             ('pgid', 124), ('ppid', os.getpid() + 1), ('status', 2),
                             ('uid', os.getuid() + 1), ('ruid', os.getuid() + 1)]:
            owner, identity = self.owner(contract)
            read = owner.library.proc_pidinfo.side_effect
            def changed(*arguments):
                result = read(*arguments)
                setattr(arguments[3]._obj, field, wrong)
                return result
            owner.library.proc_pidinfo.side_effect = changed
            with self.subTest(field=field), patch.object(contract, 'validate'), \
                    patch.object(runner.database_capture.os, 'kill') as kill:
                with self.assertRaises(RuntimeError):
                    contract.resume(Process(), owner, [identity])
                kill.assert_not_called()

    def test_unknown_foreign_changed_and_incomplete_identity_never_releases_test(self):
        contract = self.contract()
        for failure in ['unknown', 'foreign', 'unobserved', 'changed', 'short']:
            owner, identity = self.owner(contract)
            current = [identity]
            if failure == 'unknown':
                owner.known = {}
            elif failure == 'foreign':
                identity = (123, 100, 7, '/foreign/swiftpm-testing-helper', 123)
                owner.known[123] = identity
                current = [identity]
            elif failure == 'unobserved':
                current = []
            elif failure == 'changed':
                owner.verified.side_effect = [True, False]
            else:
                owner.library.proc_pidinfo.side_effect = lambda *args: ctypes.sizeof(runner.watchdog.ProcessInfo) - 1
            with self.subTest(failure=failure), patch.object(contract, 'validate'), \
                    patch.object(runner.database_capture.os, 'kill') as kill:
                with self.assertRaises(RuntimeError):
                    contract.resume(Process(), owner, current)
                kill.assert_not_called()

    def test_capture_validates_runtime_and_kernel_identity_before_continue(self):
        contract = self.contract()
        owner, identity = self.owner(contract)
        events = []
        owner.verified.side_effect = lambda value: events.append('kernel') or True
        with patch.object(contract, 'validate', side_effect=lambda: events.append('runtime')), \
                patch.object(runner.database_capture.os, 'kill', side_effect=lambda *args: events.append('continue')):
            contract.resume(Process(), owner, [identity])
        self.assertEqual(events, ['runtime', 'kernel', 'runtime', 'kernel', 'continue'])

    def test_captured_fast_exit_is_observed_without_changing_sampling_or_completion_gate(self):
        process = Process()
        owner = Ownership(process)
        events = []
        def start(selected, ownership, current):
            self.assertEqual(current, [owner.identity_value])
            events.append('captured before execution')
            selected.returncode = 0
            ownership.active = False
        clock = Clock()
        with tempfile.TemporaryDirectory() as fixture:
            output = Path(fixture)
            def launch(arguments, **kwargs):
                kwargs['stdout'].write(OriginalNativeOwnerTests().database_log().encode())
                kwargs['stdout'].flush()
                return process
            with patch.object(runner.watchdog, 'owned_crash_reports', return_value=[]):
                result = runner.run_original(
                    ['/synthetic/helper'], output, {}, output, deadline=1,
                    process_factory=launch, ownership_factory=lambda *args: owner,
                    start=start, selection='database-mutation', clock=clock.now, sleep=clock.sleep)
        self.assertTrue(result['passed'])
        self.assertTrue(result['observedTestingProcess'])
        self.assertEqual(events, ['captured before execution'])
        self.assertEqual(clock.value, 0)

    def test_failed_build_or_uncertain_cleanup_never_admits_a_selected_test(self):
        clean = {'exitCode': 0, 'timedOut': False, 'logBoundExceeded': False, 'failure': None,
                 'cleanup': {'naturalSurvivorCount': 0, 'reaped': True,
                             'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0, 'ownershipErrors': []}}
        self.assertTrue(runner.clean_result(clean))
        for key, value in [('exitCode', 1), ('timedOut', True), ('failure', 'uncertain identity')]:
            self.assertFalse(runner.clean_result(dict(clean, **{key: value})))
        for key, value in [('naturalSurvivorCount', 1), ('reaped', False),
                           ('remainingOwnedProcesses', 1), ('unverifiedOwnedProcesses', 1),
                           ('ownershipErrors', ['uncertain identity'])]:
            self.assertFalse(runner.clean_result(dict(clean, cleanup=dict(clean['cleanup'], **{key: value}))))

    def test_owned_spawn_failure_closes_actions_attributes_and_input_without_killing_any_pid(self):
        class Function:
            def __init__(self, function):
                self.function = function
            def __call__(self, *arguments):
                return self.function(*arguments)
        library = Mock()
        calls = []
        for name in ('posix_spawnattr_init', 'posix_spawnattr_destroy', 'posix_spawnattr_setflags',
                     'posix_spawnattr_setsigmask', 'posix_spawnattr_setsigdefault',
                     'posix_spawn_file_actions_init', 'posix_spawn_file_actions_destroy',
                     'posix_spawn_file_actions_adddup2', 'posix_spawn_file_actions_addchdir_np'):
            setattr(library, name, Function(lambda *args, name=name: calls.append((name, args)) or 0))
        library.posix_spawn = Function(lambda *args: 2)
        with patch.object(runner.database_capture.os, 'open', return_value=77), \
                patch.object(runner.database_capture.os, 'close') as close, \
                patch.object(runner.database_capture.os, 'kill') as kill:
            with self.assertRaises(OSError):
                runner.database_capture.SuspendedProcess(
                    ['/synthetic/helper'], {'HOME': '/synthetic'}, 78, '/synthetic', library)
            close.assert_called_once_with(77)
            kill.assert_not_called()
        flags = next(args[1] for name, args in calls if name == 'posix_spawnattr_setflags')
        self.assertEqual(flags & 0x0080, 0x0080)
        self.assertEqual(flags & 0x0400, 0x0400)
        self.assertEqual(calls[-2][0], 'posix_spawn_file_actions_destroy')
        self.assertEqual(calls[-1][0], 'posix_spawnattr_destroy')

    def test_build_query_and_selected_execution_share_the_original_total_deadline(self):
        clock = Clock()
        clean = {'exitCode': 0, 'timedOut': False, 'logBoundExceeded': False, 'failure': None,
                 'passed': False,
                 'cleanup': {'naturalSurvivorCount': 0, 'reaped': True,
                             'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0, 'ownershipErrors': []}}
        calls = []
        contract = self.contract()
        contract.validate = Mock()
        def run(arguments, root, environment, output, **kwargs):
            calls.append(kwargs['deadline'])
            if len(calls) == 1:
                clock.value = 900
                return clean
            self.assertEqual(kwargs['selection'], 'database-mutation')
            self.assertEqual(kwargs['start'], contract.resume)
            clock.value = 911
            return dict(clean, passed=True)
        def query(driver, root, environment, timeout):
            self.assertEqual(timeout, 30)
            self.assertNotIn('EDITH_DATABASE_POSTGRESQL_HOST', environment)
            clock.value = 910
            return '/synthetic/bin'
        with tempfile.TemporaryDirectory() as fixture, \
                patch.object(runner.time, 'monotonic', side_effect=clock.now), \
                patch.object(runner.database_capture, 'build_arguments', return_value=(Mock(), ['/synthetic/swift', 'build'])), \
                patch.object(runner.database_capture, 'binary_directory', side_effect=query), \
                patch.object(runner.database_capture, 'DatabaseTestContract', return_value=contract) as create, \
                patch.object(runner, 'run_original', side_effect=run):
            result = runner.run_database(Path(fixture),
                                         {'DEVELOPER_DIR': '/synthetic/developer', 'EDITH_DATABASE_POSTGRESQL_HOST': 'forbidden'},
                                         Path(fixture), 'database-mutation')
        self.assertEqual(calls, [2400, 1490])
        self.assertEqual(create.call_args.args[-1], 2400)
        self.assertTrue(result['passed'])
        self.assertEqual(result['durationSeconds'], 911)

    def test_failed_suspended_start_only_kills_and_reaps_its_unreaped_direct_child(self):
        capture = runner.database_capture
        child = capture.SuspendedProcess.__new__(capture.SuspendedProcess)
        child.pid = 123
        child.returncode = None
        with patch.object(child, 'poll', return_value=None), \
                patch.object(child, 'wait', return_value=-signal.SIGKILL) as wait, \
                patch.object(capture.os, 'kill') as kill, \
                patch.object(capture.os, 'killpg') as group:
            runner.retire_unobserved(child)
            kill.assert_called_once_with(123, signal.SIGKILL)
            wait.assert_called_once_with(timeout=5)
            group.assert_not_called()
        with patch.object(child, 'poll', return_value=0), \
                patch.object(child, 'wait', return_value=0), \
                patch.object(capture.os, 'kill') as kill:
            child.abort_suspended()
            kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
