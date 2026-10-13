from pathlib import Path
import os
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
                         '\t$(call PREPARE_ARGUMENT_PARSER,Extensions/database)\n'
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

    def test_captured_path_failure_keeps_original_sample_and_enumerated_parent(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        original_info = self.kernel.proc_pidinfo
        original_path = self.kernel.proc_pidpath

        def info(pid, flavor, argument, pointer, size):
            result = original_info(pid, flavor, argument, pointer, size)
            if pid == 234:
                pointer._obj.status = 2 if argument == 0 else 5
            return result

        def path(pid, buffer, size):
            return 0 if pid == 234 else original_path(pid, buffer, size)

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=info) as records, \
                patch.object(self.kernel, 'proc_pidpath', side_effect=path) as paths:
            self.owner.refresh()
        captured = self.owner.captured_snapshot_failures
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0]['clause'], 'executable_path_unavailable')
        self.assertEqual(captured[0]['status'], 2)
        self.assertEqual(self.owner.failure_observations[0]['status'], 5)
        self.assertTrue(all(captured[0][field] for field in [
            'pidMatches', 'uidMatches', 'realUIDMatches', 'parentEnumerated',
            'parentIdentityKnown', 'parentMatches', 'leaderGroupMatches']))
        self.assertEqual([call.args[:3] for call in records.call_args_list],
                         [(123, 3, 0), (234, 3, 0), (234, 3, 1)])
        self.assertEqual([call.args[0] for call in paths.call_args_list], [123, 234])
        self.assertEqual(self.owner.errors, ['Live owned process identity unavailable'])
        self.assertNotIn(234, self.owner.known)
        self.assertNotIn(234, self.owner.seals)
        self.assertEqual(self.kernel.signals, [])
        self.assertNotIn('private', json.dumps(captured))

    def test_missing_record_recovers_only_with_two_complete_unchanged_owned_snapshots(self):
        original = self.kernel.proc_pidinfo
        counts = []

        def info(pid, flavor, argument, pointer, size):
            counts.append(argument)
            if len(counts) == 1:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return result

        expected = self.owner.known[123]
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
            self.assertEqual(self.owner.snapshot(123)[:5], expected)
        self.assertEqual(counts, [0, 0, 0])
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.failure_observations, [])
        self.assertEqual(self.owner.captured_snapshot_failures, [])
        self.assertEqual(self.kernel.signals, [])

    def test_missing_record_cannot_recover_changed_or_incomplete_owned_identity(self):
        for field in ['pid', 'seconds', 'microseconds', 'pgid', 'uid', 'ruid', 'short',
                      'missing', 'path', 'parent', 'executable', 'status']:
            for changed_read in [2, 3]:
                with self.subTest(field=field, changed_read=changed_read):
                    owner = runner.BoundedOwnership(123, 501)
                    known = dict(owner.known)
                    seals = dict(owner.seals)
                    original = self.kernel.proc_pidinfo
                    original_path = self.kernel.proc_pidpath
                    reads = 0

                    def info(pid, flavor, argument, pointer, size):
                        nonlocal reads
                        reads += 1
                        if reads == 1:
                            return 0
                        result = original(pid, flavor, argument, pointer, size)
                        pointer._obj.status = 2
                        if reads == changed_read:
                            if field == 'short':
                                return size - 1
                            if field == 'missing':
                                return 0
                            if field not in ['path', 'executable']:
                                name = 'ppid' if field == 'parent' else field
                                setattr(pointer._obj, name, 5 if field == 'status'
                                        else getattr(pointer._obj, name) + 1)
                        return result

                    def path(pid, buffer, size):
                        if reads == changed_read and field == 'path':
                            return 0
                        if reads == changed_read and field == 'executable':
                            buffer.value = b'/synthetic/different'
                            return len(buffer.value)
                        return original_path(pid, buffer, size)

                    with patch.object(self.kernel, 'proc_pidinfo', side_effect=info), \
                            patch.object(self.kernel, 'proc_pidpath', side_effect=path):
                        with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                            owner.snapshot(123)
                    self.assertEqual(owner.known, known)
                    self.assertEqual(owner.seals, seals)
                    self.assertEqual(owner.failure_observations[0]['kind'], 'live_identity_unavailable')
                    self.assertEqual(owner.captured_snapshot_failures[0]['clause'], 'kernel_record_unavailable')
                    self.assertEqual(self.kernel.signals, [])

    def test_missing_unknown_record_never_retries_or_admits_a_live_process(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        original = self.kernel.proc_pidinfo
        counts = []

        def info(pid, flavor, argument, pointer, size):
            if pid == 234:
                counts.append(argument)
                if argument == 0:
                    return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(234)
        self.assertEqual(counts, [0, 1])
        self.assertNotIn(234, self.owner.known)
        self.assertNotIn(234, self.owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_known_path_or_user_failure_never_uses_missing_record_recovery(self):
        original = self.kernel.proc_pidinfo
        for field in ['path', 'uid', 'ruid']:
            with self.subTest(field=field):
                owner = runner.BoundedOwnership(123, 501)
                calls = []

                def info(pid, flavor, argument, pointer, size):
                    calls.append(argument)
                    result = original(pid, flavor, argument, pointer, size)
                    pointer._obj.status = 2
                    if field != 'path':
                        setattr(pointer._obj, field, 502)
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=info), \
                        patch.object(self.kernel, 'proc_pidpath', return_value=0):
                    with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                        owner.snapshot(123)
                self.assertEqual(calls, [0, 1, 1])
                self.assertEqual(self.kernel.signals, [])

    def test_recovered_read_preserves_sticky_conflicts_and_per_signal_identity_checks(self):
        expected = self.owner.known[123]
        self.owner.reject(123, 'Existing ownership failure')
        original = self.kernel.proc_pidinfo
        reads = 0

        def info(pid, flavor, argument, pointer, size):
            nonlocal reads
            reads += 1
            if reads == 1:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
            self.assertEqual(self.owner.snapshot(123)[:5], expected)
        self.assertEqual(self.owner.errors, ['Existing ownership failure'])
        self.assertEqual(self.owner.conflicts(), [expected])
        self.kernel.processes[123] = (123, 200, 7, '/fixture/reused', 123, 1, 501, 501)
        self.assertFalse(self.owner.verified(expected))
        self.assertIn('Existing ownership failure', self.owner.errors)
        self.assertEqual(self.kernel.signals, [])

    def test_inconsistent_history_never_recovers_a_missing_record(self):
        original = self.kernel.proc_pidinfo
        identity = self.owner.known[123]
        self.owner.known[123] = (123, 200, *identity[2:])
        calls = []

        def info(pid, flavor, argument, pointer, size):
            calls.append(argument)
            if argument == 0:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=info):
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(123)
        self.assertEqual(calls, [0, 1])
        self.assertEqual(self.owner.seals[123], identity[:3] + identity[4:5])
        self.assertEqual(self.kernel.signals, [])

    def test_snapshot_observer_preserves_kernel_reads_and_all_failure_clauses(self):
        cases = [('kernel_record_unavailable', None), ('effective_uid_mismatch', 6),
                 ('real_uid_mismatch', 7), ('executable_path_unavailable', 3),
                 ('invalid_process_group', 4)]
        for clause, field in cases:
            with self.subTest(clause=clause):
                traces = []
                for observing in [False, True]:
                    kernel = Kernel()
                    values = [234, 101, 8, '/fixture/compiler', 123, 123, 501, 501]
                    if field in [6, 7]:
                        values[field] = 502
                    if field == 4:
                        values[field] = 0
                    kernel.processes[234] = tuple(values)
                    original_info = kernel.proc_pidinfo
                    original_path = kernel.proc_pidpath
                    trace = []
                    captured = []

                    def info(pid, flavor, argument, pointer, size):
                        trace.append('info')
                        result = original_info(pid, flavor, argument, pointer, size)
                        return result - 1 if field is None else result

                    def path(pid, buffer, size):
                        trace.append('path')
                        return 0 if field == 3 else original_path(pid, buffer, size)

                    with patch.object(runner.watchdog.ctypes, 'CDLL', return_value=kernel), \
                            patch.object(kernel, 'proc_pidinfo', side_effect=info), \
                            patch.object(kernel, 'proc_pidpath', side_effect=path):
                        owner = runner.watchdog.OwnedProcesses(123, 501)
                        callback = (lambda reason, count, record: captured.append(reason)) if observing else None
                        self.assertIsNone(owner.snapshot(234, callback))
                    traces.append(trace)
                    self.assertEqual(captured, [clause] if observing else [])
                self.assertEqual(traces[0], traces[1])

    def test_captured_failures_deduplicate_and_bound_without_changing_ownership(self):
        self.owner.refresh()
        self.assertEqual(self.owner.captured_snapshot_failures, [])
        for pid in range(200, 212):
            self.kernel.processes[pid] = (pid, pid, 7, '/fixture/private', 123, 123, 501, 501)
        original = self.kernel.proc_pidpath
        with patch.object(self.kernel, 'proc_pidpath',
                          side_effect=lambda pid, buffer, size: 0 if pid >= 200 else original(pid, buffer, size)):
            self.owner.refresh()
            self.owner.refresh()
        self.assertEqual(len(self.owner.captured_snapshot_failures), 8)
        self.assertEqual(len(self.owner.captured_snapshot_keys), 8)
        self.assertEqual(self.owner.errors, ['Live owned process identity unavailable'])
        self.assertEqual(set(self.owner.known), {123})
        self.assertEqual(self.kernel.signals, [])
        self.assertNotIn('private', json.dumps(self.owner.captured_snapshot_failures))

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

    def test_unknown_zombie_without_enumerated_parent_never_suppresses_failure(self):
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
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(234)
        self.assertNotIn(234, self.owner.seals)
        self.assertNotIn(234, self.owner.known)
        self.assertEqual(self.owner.errors, [])
        self.assertIs(self.owner.failure_observations[0]['knownSeal'], False)
        self.assertEqual(self.kernel.signals, [])

    def terminal_probe(self, pid, flavor, argument, pointer, size):
        if pid == 234 and argument == 0:
            return 0
        result = self.kernel_record(pid, flavor, argument, pointer, size)
        pointer._obj.status = 5 if pid == 234 else 2
        return result

    def test_terminal_child_rejects_nonpositive_and_noninteger_identifiers_before_queries(self):
        invalid = [0, -1, True, False, '234', None]
        for pid, parent in [(value, 123) for value in invalid] + [(234, value) for value in invalid]:
            with self.subTest(pid=pid, parent=parent), \
                    patch.object(self.owner, 'recover_snapshot') as parents, \
                    patch.object(self.kernel, 'proc_pidinfo') as records:
                self.assertFalse(self.owner.terminal_child(pid, parent, self.owner.known[123]))
                parents.assert_not_called()
                records.assert_not_called()
        self.assertEqual(self.owner.terminal_children, {})
        self.assertEqual(self.kernel.signals, [])

    def test_fresh_enumerated_terminal_child_is_never_executable_or_signal_authority(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/never-read', 123, 123, 501, 501)
        self.kernel_record = self.kernel.proc_pidinfo
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=self.terminal_probe) as records, \
                patch.object(self.kernel, 'proc_pidpath', wraps=self.kernel.proc_pidpath) as paths:
            self.assertEqual({item[0] for item in self.owner.refresh()}, {123})
            self.assertEqual([call.args[2] for call in records.call_args_list if call.args[0] == 234], [0, 1, 1])
            self.assertNotIn(234, [call.args[0] for call in paths.call_args_list])
        self.assertIn(234, self.owner.terminal_children)
        self.assertNotIn(234, self.owner.seals)
        self.assertNotIn(234, self.owner.known)
        self.assertEqual(self.owner.errors, [])
        self.assertEqual(self.owner.failure_observations, [])
        self.assertEqual(self.owner.captured_snapshot_failures, [])
        self.assertEqual(self.kernel.signals, [])

    def test_terminal_child_requires_two_complete_equal_owned_kernel_records(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        self.kernel_record = self.kernel.proc_pidinfo
        cases = {'pid': 456, 'seconds': 0, 'microseconds': 1000000,
                 'pgid': 456, 'ppid': 456, 'uid': 502, 'ruid': 502, 'status': 2,
                 'flags': 1, 'xstatus': 1, 'nfiles': 1, 'short': 135, 'boolean': True}
        for field, value in cases.items():
            for changed_read in [1, 2]:
                with self.subTest(field=field, changed_read=changed_read):
                    owner = runner.BoundedOwnership(123, 501)
                    reads = 0

                    def probe(pid, flavor, argument, pointer, size):
                        nonlocal reads
                        result = self.terminal_probe(pid, flavor, argument, pointer, size)
                        if pid == 234 and argument == 1:
                            reads += 1
                            if reads == changed_read:
                                if field in ['short', 'boolean']:
                                    return value
                                setattr(pointer._obj, field, value)
                        return result

                    with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe):
                        owner.refresh()
                    self.assertNotIn(234, owner.terminal_children)
                    self.assertNotIn(234, owner.seals)
                    self.assertNotIn(234, owner.known)
                    self.assertEqual(owner.errors, ['Live owned process identity unavailable'])
                    self.assertEqual(self.kernel.signals, [])

    def test_terminal_child_revalidates_actual_parent_before_and_after_child_reads(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        self.kernel_record = self.kernel.proc_pidinfo
        original_path = self.kernel.proc_pidpath
        for field in ['seconds', 'microseconds', 'pgid', 'pid', 'uid', 'ruid', 'path', 'missing']:
            for changed_read in [2, 4]:
                with self.subTest(field=field, changed_read=changed_read):
                    owner = runner.BoundedOwnership(123, 501)
                    parent_reads = 0
                    changed = False

                    def probe(pid, flavor, argument, pointer, size):
                        nonlocal parent_reads, changed
                        result = self.terminal_probe(pid, flavor, argument, pointer, size)
                        if pid == 123 and argument == 0:
                            parent_reads += 1
                            changed = parent_reads == changed_read
                            if changed:
                                if field == 'missing':
                                    return 0
                                if field != 'path':
                                    setattr(pointer._obj, field, getattr(pointer._obj, field) + 1)
                        return result

                    def path(pid, buffer, size):
                        result = original_path(pid, buffer, size)
                        if pid == 123 and changed and field == 'path':
                            buffer.value = b'/fixture/replaced'
                        return result

                    with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe), \
                            patch.object(self.kernel, 'proc_pidpath', side_effect=path):
                        owner.refresh()
                    self.assertNotIn(234, owner.terminal_children)
                    self.assertNotIn(234, owner.seals)
                    self.assertTrue(owner.errors)
                    self.assertEqual(self.kernel.signals, [])

    def test_terminal_child_reuse_or_later_live_record_fails_without_signal_authority(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        self.kernel_record = self.kernel.proc_pidinfo
        for changed in ['birth', 'live']:
            with self.subTest(changed=changed):
                self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                with patch.object(self.kernel, 'proc_pidinfo', side_effect=self.terminal_probe):
                    owner.refresh()
                    if changed == 'birth':
                        self.kernel.processes[234] = (234, 200, 8, '/fixture/private', 123, 123, 501, 501)
                        owner.refresh()
                if changed == 'live':
                    owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.seals)
                self.assertNotIn(234, owner.known)
                self.assertEqual(self.kernel.signals, [])

    def test_terminal_child_lifetime_bound_and_existing_errors_remain_fail_closed(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private', 123, 123, 501, 501)
        self.kernel_record = self.kernel.proc_pidinfo
        for full in [False, True]:
            owner = runner.BoundedOwnership(123, 501)
            owner.reject(123, 'Existing ownership failure')
            if full:
                owner.terminal_children = {pid: b'bounded' for pid in range(1000, 5095)}
            with patch.object(self.kernel, 'proc_pidinfo', side_effect=self.terminal_probe):
                owner.refresh()
            self.assertIn('Existing ownership failure', owner.errors)
            self.assertEqual(234 in owner.terminal_children, not full)
            self.assertNotIn(234, owner.seals)
            self.assertEqual(self.kernel.signals, [])

    def test_terminal_only_child_cannot_fabricate_test_completion_or_skip_natural_join(self):
        for code, observed, expected in [(0, True, True), (2, True, False), (0, False, False)]:
            with self.subTest(code=code, observed=observed):
                self.kernel.processes = {
                    123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501),
                    234: (234, 101, 8, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)}
                if observed:
                    self.kernel.processes[345] = (
                        345, 102, 9, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                self.kernel_record = self.kernel.proc_pidinfo
                original_refresh = owner.refresh

                def refresh():
                    rows = original_refresh()
                    self.kernel.processes.clear()
                    return rows

                text = ('Test run with 47 tests in 9 suites passed.\n' if code == 0
                        else 'Test run with 47 tests in 9 suites failed with 1 issue.\n')
                with patch.object(self.kernel, 'proc_pidinfo', side_effect=self.terminal_probe), \
                        patch.object(owner, 'refresh', side_effect=refresh):
                    result, _, _ = OriginalNativeOwnerTests.run_fixture(self, text, Process(code), owner)
                self.assertIs(result['passed'], expected)
                self.assertIs(result['observedTestingProcess'], observed)
                self.assertEqual(result['exitCode'], code)
                self.assertTrue(result['cleanup']['reaped'])
                for key in ['naturalSurvivorCount', 'remainingOwnedProcesses', 'unverifiedOwnedProcesses']:
                    self.assertEqual(result['cleanup'][key], 0)
                self.assertEqual(result['cleanup']['ownershipErrors'], [])
                self.assertNotIn(234, [row[0] for row in result['knownOwnedProcesses']])
                self.assertNotIn(234, owner.seals)
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


class ChildSelfGroupContracts(unittest.TestCase):
    def setUp(self):
        self.kernel = Kernel()
        original = self.kernel.proc_pidinfo

        def live(pid, flavor, argument, pointer, size):
            result = original(pid, flavor, argument, pointer, size)
            if result == size:
                pointer._obj.status = 2
            return result

        self.kernel.proc_pidinfo = live
        self.library = patch.object(runner.watchdog.ctypes, 'CDLL', return_value=self.kernel)
        self.kill = patch.object(runner.os, 'kill', side_effect=self.kernel.kill)
        self.library.start()
        self.kill.start()
        self.addCleanup(self.library.stop)
        self.addCleanup(self.kill.stop)

    def admitted_child(self):
        self.kernel.processes = {
            123: (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501),
            234: (234, 101, 8, '/fixture/swiftpm-testing-helper', 123, 123, 501, 501),
        }
        owner = runner.BoundedOwnership(123, 501)
        owner.refresh()
        self.assertEqual(owner.errors, [])
        self.assertEqual(owner.admission_parents[234], self.kernel.processes[123])
        self.assertEqual(owner.parents[234], 123)
        return owner

    def self_group(self):
        child = list(self.kernel.processes[234])
        child[4] = 234
        self.kernel.processes[234] = tuple(child)

    def test_real_admission_preserves_original_parent_and_one_strict_self_group(self):
        owner = self.admitted_child()
        original = owner.seals[234]
        parent = owner.admission_parents[234]
        self.self_group()
        rows = owner.refresh()
        self.assertIn(self.kernel.processes[234][:5], rows)
        self.assertEqual(owner.seals[234], original)
        self.assertEqual(owner.admission_parents[234], parent)
        self.assertEqual(owner.current_seal(234), (234, 101, 8, 234))
        self.assertEqual(owner.child_group_transitions[234],
                         ((234, 101, 8, '/fixture/swiftpm-testing-helper', 123),
                          self.kernel.processes[234][:5], parent))
        self.assertTrue(all(owner.self_group_observations[234].values()))
        self.assertEqual(owner.errors, [])
        self.assertEqual(owner.conflicts(), [])

    def test_child_identity_foreign_group_and_parent_changes_never_admit(self):
        for index, changed in [(0, 999), (1, 201), (2, 9), (3, '/fixture/changed'),
                               (4, 456), (5, 345), (6, 502), (7, 502)]:
            with self.subTest(index=index):
                owner = self.admitted_child()
                self.self_group()
                child = list(self.kernel.processes[234])
                child[index] = changed
                self.kernel.processes[234] = tuple(child)
                owner.refresh()
                self.assertNotIn(234, owner.child_self_groups)
                self.assertTrue(owner.errors)
                self.assertEqual(len(owner.conflicts()), 1)
                self.assertEqual(self.kernel.signals, [])

    def test_leader_unknown_and_unretained_parent_cannot_adopt_self_group(self):
        owner = self.admitted_child()
        leader = list(self.kernel.processes[123])
        leader[4] = 345
        self.kernel.processes[123] = tuple(leader)
        owner.refresh()
        self.assertTrue(owner.errors)
        self.assertNotIn(123, owner.child_self_groups)
        self.assertFalse(owner.admit_child_self_group(456, (456, 101, 8, '/fixture/unknown', 456)))
        owner = self.admitted_child()
        del owner.admission_parents[234]
        self.self_group()
        owner.refresh()
        self.assertTrue(owner.errors)
        self.assertNotIn(234, owner.admission_parents)
        self.assertNotIn(234, owner.child_self_groups)

    def test_child_full_kernel_records_must_be_complete_live_and_identical(self):
        for changed in ['incomplete', 'status', 'volatile', 'time']:
            with self.subTest(changed=changed):
                owner = self.admitted_child()
                self.self_group()
                original = self.kernel.proc_pidinfo
                reads = 0

                def probe(pid, flavor, argument, pointer, size):
                    nonlocal reads
                    result = original(pid, flavor, argument, pointer, size)
                    if pid == 234:
                        reads += 1
                        if reads == 3:
                            if changed == 'incomplete':
                                return size - 1
                            if changed == 'status':
                                pointer._obj.status = 5
                            if changed == 'volatile':
                                pointer._obj.nfiles = 1
                            if changed == 'time':
                                pointer._obj.microseconds = 1_000_000
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe):
                    owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.child_self_groups)
                self.assertFalse(owner.self_group_observations[234]['twoChildRecordsMatch'])

    def test_original_parent_is_revalidated_before_and_after_child_records(self):
        for changed_read in [1, 2]:
            for field in ['birth', 'group', 'uid', 'real_uid', 'parent', 'missing', 'volatile']:
                with self.subTest(read=changed_read, field=field):
                    owner = self.admitted_child()
                    self.self_group()
                    original = self.kernel.proc_pidinfo
                    reads = 0

                    def probe(pid, flavor, argument, pointer, size):
                        nonlocal reads
                        result = original(pid, flavor, argument, pointer, size)
                        if pid == 123:
                            reads += 1
                            if reads == changed_read:
                                if field == 'missing':
                                    return 0
                                attribute = {'birth': 'seconds', 'group': 'pgid', 'uid': 'uid',
                                             'real_uid': 'ruid', 'parent': 'ppid', 'volatile': 'nfiles'}[field]
                                setattr(pointer._obj, attribute, getattr(pointer._obj, attribute) + 1)
                        return result

                    with patch.object(self.kernel, 'proc_pidinfo', side_effect=probe):
                        owner.refresh()
                    self.assertTrue(owner.errors)
                    self.assertNotIn(234, owner.child_self_groups)

    def test_parent_executable_change_cannot_be_inferred_from_current_parent(self):
        owner = self.admitted_child()
        self.self_group()
        parent = list(self.kernel.processes[123])
        parent[3] = '/fixture/new-parent'
        self.kernel.processes[123] = tuple(parent)
        owner.refresh()
        self.assertTrue(owner.errors)
        self.assertNotIn(234, owner.child_self_groups)
        self.assertFalse(owner.self_group_observations[234]['parentBeforeMatches'])

    def test_second_group_transition_and_prior_rejection_stay_failed(self):
        owner = self.admitted_child()
        self.self_group()
        owner.refresh()
        child = list(self.kernel.processes[234])
        child[4] = 123
        self.kernel.processes[234] = tuple(child)
        owner.refresh()
        self.assertTrue(owner.errors)
        self.assertEqual(owner.child_self_groups[234], 234)
        owner = self.admitted_child()
        child = list(self.kernel.processes[234])
        child[4] = 456
        self.kernel.processes[234] = tuple(child)
        owner.refresh()
        rejected = list(owner.conflicts())
        self.self_group()
        owner.refresh()
        self.assertNotIn(234, owner.child_self_groups)
        self.assertEqual(owner.conflicts(), rejected)
        self.assertTrue(owner.errors)

    def test_signals_revalidate_each_pid_and_never_signal_child_group(self):
        owner = self.admitted_child()
        self.self_group()
        owner.refresh()
        with patch.object(runner.os, 'killpg') as groups:
            owner.terminate(signal.SIGTERM)
            groups.assert_not_called()
        self.assertIn((234, signal.SIGTERM), self.kernel.signals)
        self.kernel.signals.clear()
        original = owner.verified

        def changed(identity):
            if identity[0] == 234:
                child = list(self.kernel.processes[234])
                child[1] += 1
                self.kernel.processes[234] = tuple(child)
            return original(identity)

        with patch.object(owner, 'verified', side_effect=changed), patch.object(runner.os, 'killpg') as groups:
            owner.terminate(signal.SIGKILL)
            groups.assert_not_called()
        self.assertNotIn((234, signal.SIGKILL), self.kernel.signals)
        self.assertTrue(owner.errors)

    def test_descendants_remain_owned_after_group_transition_and_parent_exit(self):
        owner = self.admitted_child()
        self.self_group()
        owner.refresh()
        self.kernel.processes[345] = (345, 102, 9, '/fixture/descendant', 234, 234, 501, 501)
        rows = owner.refresh()
        self.assertIn(self.kernel.processes[345][:5], rows)
        self.assertEqual(owner.admission_parents[345], self.kernel.processes[234])
        del self.kernel.processes[123]
        clock = Clock()
        cleanup = runner.retire(Process(0), owner, clock.now, clock.sleep)
        self.assertGreater(cleanup['naturalSurvivorCount'], 0)
        self.assertGreater(cleanup['remainingOwnedProcesses'], 0)
        self.assertTrue(cleanup['reaped'])

    def test_real_runner_still_requires_completion_and_natural_join(self):
        for text, expected in [('Test run with 19 tests in 4 suites passed.\n', True),
                               ('Test run with 0 tests passed.\n', False), ('Build complete!\n', False)]:
            with self.subTest(text=text):
                owner = self.admitted_child()
                self.self_group()
                original = owner.refresh
                first = True

                def refresh():
                    nonlocal first
                    rows = original()
                    if first:
                        first = False
                        self.kernel.processes.clear()
                    return rows

                process = Process(0)
                with patch.object(owner, 'refresh', side_effect=refresh):
                    result, _, _ = OriginalNativeOwnerTests.run_fixture(self, text, process, owner)
                self.assertIs(result['passed'], expected)
                self.assertEqual(result['cleanup']['remainingOwnedProcesses'], 0)
                self.assertEqual(result['cleanup']['unverifiedOwnedProcesses'], 0)
                self.assertEqual(result['cleanup']['ownershipErrors'], [])
                self.assertTrue(result['childSelfGroupObservations'][0]['transitionAdmitted'])
                self.assertEqual(process.reaps, 1)
                self.assertEqual(self.kernel.signals, [])

    def test_approved_group_recovery_and_terminal_retirement_preserve_original_seals(self):
        owner = self.admitted_child()
        original_seal = owner.seals[234]
        self.self_group()
        owner.refresh()
        transition = owner.child_group_transitions[234]
        original = self.kernel.proc_pidinfo
        reads = 0

        def missing_once(pid, flavor, argument, pointer, size):
            nonlocal reads
            if pid == 234:
                reads += 1
                if reads == 1:
                    return 0
            return original(pid, flavor, argument, pointer, size)

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=missing_once):
            self.assertEqual(owner.snapshot(234), self.kernel.processes[234][:6])
        self.assertEqual(reads, 3)
        self.assertEqual(owner.seals[234], original_seal)

        def zombie(pid, flavor, argument, pointer, size):
            if pid == 234 and argument == 0:
                return 0
            result = original(pid, flavor, argument, pointer, size)
            if pid == 234:
                pointer._obj.status = 5
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=zombie):
            owner.refresh()
        self.assertNotIn(234, owner.known)
        self.assertEqual(owner.seals[234], original_seal)
        self.assertEqual(owner.child_group_transitions[234], transition)
        self.assertEqual(owner.errors, [])
        self.assertEqual(owner.conflicts(), [])
        child = list(self.kernel.processes[234])
        child[1] += 1
        self.kernel.processes[234] = tuple(child)
        owner.refresh()
        self.assertTrue(owner.errors)
        self.assertEqual(owner.child_group_transitions[234], transition)
        self.assertEqual(self.kernel.signals, [])


class PendingKernelChildContracts(unittest.TestCase):
    setUp = ChildSelfGroupContracts.setUp

    def missing_child(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        owner = runner.BoundedOwnership(123, 501)
        original = self.kernel.proc_pidinfo

        def unavailable(pid, flavor, argument, pointer, size):
            return 0 if pid == 234 else original(pid, flavor, argument, pointer, size)

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=unavailable):
            self.assertEqual(owner.refresh(), [self.kernel.processes[123][:5]])
        self.assertEqual(owner.errors, [])
        self.assertEqual(owner.pending_children, {234: self.kernel.processes[123]})
        self.assertNotIn(234, owner.seals)
        self.assertNotIn(234, owner.known)
        return owner

    def test_fresh_kernel_gap_waits_without_executable_or_signal_authority(self):
        owner = self.missing_child()
        original = self.kernel.proc_pidinfo
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=lambda pid, *args:
                          0 if pid == 234 else original(pid, *args)):
            owner.terminate(signal.SIGTERM)
        self.assertEqual(self.kernel.signals, [(123, signal.SIGTERM)])
        self.assertNotIn(234, owner.known)
        self.assertEqual(owner.errors, [])

    def test_complete_stable_parent_and_child_resolve_to_original_admission(self):
        owner = self.missing_child()
        leader_seal = owner.seals[123]
        rows = owner.refresh()
        self.assertIn(self.kernel.processes[234][:5], rows)
        self.assertEqual(owner.pending_children, {})
        self.assertEqual(owner.seals[123], leader_seal)
        self.assertEqual(owner.seals[234], (234, 101, 8, 123))
        self.assertEqual(owner.admission_parents[234], self.kernel.processes[123])
        self.assertEqual(owner.errors, [])
        self.assertEqual(self.kernel.signals, [])

    def test_non_kernel_failures_never_acquire_pending_authority(self):
        for field in ['uid', 'ruid', 'path', 'group']:
            with self.subTest(field=field):
                self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
                original = self.kernel.proc_pidinfo
                original_path = self.kernel.proc_pidpath

                def record(pid, flavor, argument, pointer, size):
                    result = original(pid, flavor, argument, pointer, size)
                    if pid == 234 and field != 'path':
                        setattr(pointer._obj, 'pgid' if field == 'group' else field,
                                0 if field == 'group' else 502)
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=record), \
                        patch.object(self.kernel, 'proc_pidpath', side_effect=lambda pid, *args:
                                     0 if pid == 234 and field == 'path' else original_path(pid, *args)):
                    owner = runner.BoundedOwnership(123, 501)
                    owner.refresh()
                self.assertEqual(owner.pending_children, {})
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_unknown_unenumerated_pid_and_leader_never_acquire_pending_status(self):
        owner = runner.BoundedOwnership(123, 501)
        self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
        with patch.object(self.kernel, 'proc_pidinfo', return_value=0):
            for pid in [123, 234]:
                with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                    owner.snapshot(pid)
        self.assertEqual(owner.pending_children, {})
        self.assertEqual(self.kernel.signals, [])

    def test_pending_parent_cannot_change_birth_path_group_or_users(self):
        for field in [1, 3, 4, 6, 7]:
            with self.subTest(field=field):
                self.kernel.processes[123] = (123, 100, 7, '/usr/bin/make', 123, 1, 501, 501)
                owner = self.missing_child()
                parent = list(self.kernel.processes[123])
                parent[field] = '/fixture/changed-parent' if field == 3 else parent[field] + 1
                self.kernel.processes[123] = tuple(parent)
                owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.seals)
                self.assertIn(234, owner.pending_failures)
        self.assertEqual(self.kernel.signals, [])

    def test_pending_child_requires_two_complete_equal_full_records(self):
        for field in ['short', 'missing', 'pid', 'seconds', 'microseconds', 'pgid', 'ppid',
                      'uid', 'ruid', 'status', 'nfiles']:
            with self.subTest(field=field):
                owner = self.missing_child()
                original = self.kernel.proc_pidinfo
                reads = 0

                def record(pid, flavor, argument, pointer, size):
                    nonlocal reads
                    result = original(pid, flavor, argument, pointer, size)
                    if pid == 234:
                        reads += 1
                        if reads == 3:
                            if field in ['short', 'missing']:
                                return size - 1 if field == 'short' else 0
                            setattr(pointer._obj, field, getattr(pointer._obj, field) + 1)
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=record):
                    owner.refresh()
                self.assertTrue(owner.errors)
                self.assertNotIn(234, owner.seals)
                self.assertIn(234, owner.pending_failures)
        self.assertEqual(self.kernel.signals, [])

    def test_pending_child_changed_group_or_path_is_permanent_even_after_recovery(self):
        for field in [3, 4, 5, 6, 7]:
            with self.subTest(field=field):
                owner = self.missing_child()
                original = self.kernel.processes[234]
                value = list(original)
                value[field] = '/fixture/different' if field == 3 else value[field] + 1
                self.kernel.processes[234] = tuple(value)
                if field == 3:
                    original_path = self.kernel.proc_pidpath
                    reads = 0

                    def path(pid, buffer, size):
                        nonlocal reads
                        result = original_path(pid, buffer, size)
                        if pid == 234:
                            reads += 1
                            if reads == 3:
                                buffer.value = b'/fixture/changed-again'
                        return result

                    with patch.object(self.kernel, 'proc_pidpath', side_effect=path):
                        owner.refresh()
                else:
                    owner.refresh()
                self.assertTrue(owner.errors)
                errors = list(owner.errors)
                self.kernel.processes[234] = original
                owner.refresh()
                self.assertNotIn(234, owner.known)
                self.assertNotIn(234, owner.seals)
                self.assertTrue(all(error in owner.errors for error in errors))
        self.assertEqual(self.kernel.signals, [])

    def test_unresolved_live_pending_child_fails_after_join_and_stays_rejected(self):
        owner = self.missing_child()
        original = self.kernel.proc_pidinfo
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=lambda pid, *args:
                          0 if pid == 234 else original(pid, *args)), \
                patch.object(self.kernel, 'proc_pidpath', return_value=0):
            owner.finalize_pending_children(True)
        self.assertEqual(owner.errors, ['Pending owned child identity unresolved after join'])
        self.assertIn(234, owner.pending_failures)
        owner.refresh()
        self.assertNotIn(234, owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_absence_requires_join_two_zero_kernel_records_and_two_esrch_checks(self):
        for reaped in [False, True]:
            with self.subTest(reaped=reaped):
                owner = self.missing_child()
                self.kernel.processes.pop(234)
                with patch.object(self.kernel, 'proc_pidinfo', wraps=self.kernel.proc_pidinfo) as info, \
                        patch.object(runner.os, 'kill', side_effect=self.kernel.kill) as kills:
                    owner.finalize_pending_children(reaped)
                self.assertEqual(234 in owner.pending_children, not reaped)
                self.assertEqual(bool(owner.errors), not reaped)
                self.assertEqual(len(info.call_args_list), 2 if reaped else 0)
                self.assertEqual(kills.call_args_list,
                                 [unittest.mock.call(234, 0)] * 2 if reaped else [])
        self.assertEqual(self.kernel.signals, [])

    def test_absence_never_accepts_partial_record_path_or_reused_live_pid(self):
        for field in ['partial', 'path', 'alive', 'second-record']:
            with self.subTest(field=field):
                owner = self.missing_child()
                self.kernel.processes.pop(234)
                reads = 0

                def record(pid, flavor, argument, pointer, size):
                    nonlocal reads
                    reads += 1
                    return size - 1 if field == 'partial' or field == 'second-record' and reads == 2 else 0

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=record), \
                        patch.object(self.kernel, 'proc_pidpath', return_value=1 if field == 'path' else 0), \
                        patch.object(runner.os, 'kill', side_effect=None if field == 'alive' else ProcessLookupError()):
                    owner.finalize_pending_children(True)
                self.assertTrue(owner.errors)
                self.assertIn(234, owner.pending_failures)
                self.assertIn(234, owner.pending_children)
        self.assertEqual(self.kernel.signals, [])

    def test_pending_lifetime_and_concurrent_caps_never_expand(self):
        for full in ['lifetime', 'concurrent']:
            with self.subTest(full=full):
                self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                if full == 'lifetime':
                    owner.terminal_children = {pid: b'bounded' for pid in range(1000, 5095)}
                else:
                    owner.pending_children = {pid: self.kernel.processes[123] for pid in range(1000, 1063)}
                original = self.kernel.proc_pidinfo
                with patch.object(self.kernel, 'proc_pidinfo', side_effect=lambda pid, *args:
                                  0 if pid == 234 else original(pid, *args)):
                    owner.refresh()
                self.assertNotIn(234, owner.pending_children)
                self.assertTrue(owner.errors)
        self.assertEqual(self.kernel.signals, [])

    def test_gone_pending_resolution_does_not_clear_sticky_ownership_failures(self):
        owner = self.missing_child()
        owner.reject(123, 'Existing permanent failure')
        self.kernel.processes.pop(234)
        owner.finalize_pending_children(True)
        self.assertEqual(owner.pending_children, {})
        self.assertEqual(owner.errors, ['Existing permanent failure'])
        self.assertEqual(owner.conflicts(), [self.kernel.processes[123][:5]])
        self.assertEqual(self.kernel.signals, [])


    def test_final_retirement_resolves_absence_only_after_actual_owned_wait(self):
        owner = self.missing_child()
        self.kernel.processes.clear()
        process = Process(0)
        waited = []
        original_wait = process.wait

        def wait(timeout):
            waited.append(timeout)
            self.assertIn(234, owner.pending_children)
            return original_wait(timeout)

        process.wait = wait
        cleanup = runner.retire(process, owner, lambda: 0, lambda _: None)
        self.assertEqual(waited, [5])
        self.assertTrue(cleanup['reaped'])
        self.assertEqual(cleanup['naturalSurvivorCount'], 0)
        self.assertEqual(cleanup['remainingOwnedProcesses'], 0)
        self.assertEqual(cleanup['ownershipErrors'], [])
        self.assertEqual(owner.pending_children, {})
        self.assertEqual(self.kernel.signals, [])

    def test_parent_complete_raw_record_must_stay_stable_across_pending_resolution(self):
        owner = self.missing_child()
        original = self.kernel.proc_pidinfo
        reads = 0

        def record(pid, flavor, argument, pointer, size):
            nonlocal reads
            result = original(pid, flavor, argument, pointer, size)
            if pid == 123:
                reads += 1
                if reads == 3:
                    pointer._obj.nfiles += 1
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record):
            owner.refresh()
        self.assertTrue(owner.errors)
        self.assertNotIn(234, owner.known)
        self.assertNotIn(234, owner.seals)
        self.assertEqual(self.kernel.signals, [])


    def test_unverifiable_absence_is_retained_as_failure_without_signals(self):
        owner = self.missing_child()
        self.kernel.processes.pop(234)
        with patch.object(runner.os, 'kill', side_effect=PermissionError('synthetic unavailable')):
            owner.finalize_pending_children(True)
        self.assertEqual(owner.errors, ['Pending owned child identity unresolved after join'])
        self.assertIn(234, owner.pending_failures)
        self.assertIn(234, owner.pending_children)
        self.assertEqual(self.kernel.signals, [])


    def test_initial_partial_or_negative_kernel_results_never_defer_after_later_zeros(self):
        for first in [-1, 135]:
            with self.subTest(first=first):
                self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                original = self.kernel.proc_pidinfo
                reads = 0

                def record(pid, flavor, argument, pointer, size):
                    nonlocal reads
                    if pid == 234:
                        reads += 1
                        return first if reads == 1 else 0
                    return original(pid, flavor, argument, pointer, size)

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=record):
                    owner.refresh()
                self.assertEqual(owner.pending_children, {})
                self.assertNotIn(234, owner.seals)
                self.assertNotIn(234, owner.known)
                self.assertEqual(owner.errors, ['Live owned process identity unavailable'])
                self.assertEqual(owner.captured_snapshot_failures[0]['returnedBytes'], first)
        self.assertEqual(self.kernel.signals, [])

    def test_regular_fresh_admission_accounts_for_all_existing_pending_before_authority(self):
        for bound in ['lifetime', 'concurrent']:
            with self.subTest(bound=bound):
                self.kernel.processes[234] = (234, 101, 8, '/fixture/compiler', 123, 123, 501, 501)
                owner = runner.BoundedOwnership(123, 501)
                if bound == 'lifetime':
                    owner.terminal_children = {pid: b'bounded' for pid in range(1000, 5032)}
                count = 63
                owner.pending_children = {pid: self.kernel.processes[123] for pid in range(6000, 6000 + count)}
                rows = owner.refresh()
                self.assertNotIn(self.kernel.processes[234][:5], rows)
                self.assertNotIn(234, owner.known)
                self.assertNotIn(234, owner.seals)
                self.assertNotIn(234, owner.admission_parents)
                self.assertTrue(owner.errors)
                self.assertIn('Owned ' + bound + ' process bound exceeded' if bound == 'lifetime'
                              else 'Owned concurrent descendant bound exceeded', owner.errors)
                self.assertEqual(len(owner.pending_children), count)
        self.assertEqual(self.kernel.signals, [])

    def test_pending_promotion_at_exact_combined_caps_never_double_counts_current_pid(self):
        owner = self.missing_child()
        owner.terminal_children = {pid: b'bounded' for pid in range(1000, 5032)}
        owner.pending_children.update({pid: self.kernel.processes[123] for pid in range(6000, 6062)})
        self.assertEqual(owner.lifetime_count(), 4096)
        rows = owner.refresh()
        self.assertIn(self.kernel.processes[234][:5], rows)
        self.assertNotIn(234, owner.pending_children)
        self.assertEqual(len(owner.pending_children), 62)
        self.assertEqual(owner.lifetime_count(), 4096)
        self.assertEqual(owner.errors, [])
        self.assertEqual(self.kernel.signals, [])


class TerminalRefusalWitnessTests(unittest.TestCase):
    def setUp(self):
        self.kernel = Kernel()
        library = patch.object(runner.watchdog.ctypes, 'CDLL', return_value=self.kernel)
        kill = patch.object(runner.os, 'kill', side_effect=self.kernel.kill)
        library.start()
        kill.start()
        self.addCleanup(library.stop)
        self.addCleanup(kill.stop)
        self.owner = runner.BoundedOwnership(123, 501)

    def test_admitted_parent_own_group_refusal_records_only_original_comparisons(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private-parent', 234, 123, 501, 501)
        parent = self.kernel.processes[234][:5]
        self.owner.known[234] = parent
        self.owner.seals[234] = parent[:3] + parent[4:5]
        with patch.object(self.kernel, 'proc_pidinfo', wraps=self.kernel.proc_pidinfo) as reads:
            self.assertFalse(self.owner.terminal_child(345, 234, parent))
        reads.assert_not_called()
        row = self.owner.terminal_child_refusals[345]
        self.assertEqual(row['terminalRefusalReason'], 'parent_admission')
        self.assertEqual(row['terminalChildRole'], 'unsealed')
        self.assertTrue(row['terminalParentIdentityKnown'])
        self.assertTrue(row['terminalParentGroupMatchesSeal'])
        self.assertTrue(row['terminalParentGroupIsSelf'])
        self.assertFalse(row['terminalParentGroupMatchesLeader'])
        self.assertIsNone(row['terminalChildGroupMatchesParent'])
        self.assertIsNone(row['terminalRawRecordsStable'])
        self.assertEqual(self.owner.terminal_children, {})
        self.assertNotIn(345, self.owner.known)
        self.assertNotIn(345, self.owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_first_zero_record_witness_survives_later_zombie_diagnostic_without_new_queries(self):
        self.kernel.processes[234] = (234, 101, 8, '/fixture/private-child', 123, 123, 501, 501)
        original = self.kernel.proc_pidinfo
        children = 0

        def record(pid, flavor, argument, pointer, size):
            nonlocal children
            value = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 5 if pid == 234 else 2
            if pid == 234:
                children += 1
                if children == 1:
                    return 0
            return value

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record) as reads:
            self.assertFalse(self.owner.terminal_child(234, 123, self.owner.known[123]))
            self.owner.observe_failure(234, 'live_identity_unavailable')
        self.assertEqual([call.args[0] for call in reads.call_args_list], [123, 123, 234, 234])
        row = self.owner.failure_observations[0]
        self.assertEqual(row['terminalRefusalReason'], 'first_child_record')
        self.assertFalse(row['terminalChildRecordComplete'])
        self.assertIsNone(row['terminalChildIsZombie'])
        self.assertEqual(row['status'], 5)
        self.assertTrue(row['terminalParentGroupMatchesSeal'])
        self.assertEqual(self.owner.terminal_children, {})
        self.assertNotIn(234, self.owner.known)
        self.assertNotIn(234, self.owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_complete_records_distinguish_child_group_instability_and_parent_after_refusal(self):
        for mode in ['group', 'volatile', 'parent']:
            with self.subTest(mode=mode):
                owner = runner.BoundedOwnership(123, 501)
                self.kernel.processes[234] = (234, 101, 8, '/fixture/private-child', 123, 123, 501, 501)
                original = self.kernel.proc_pidinfo
                children = 0

                def record(pid, flavor, argument, pointer, size):
                    nonlocal children
                    result = original(pid, flavor, argument, pointer, size)
                    pointer._obj.status = 5 if pid == 234 else 2
                    if pid == 234:
                        children += 1
                        if mode == 'group':
                            pointer._obj.pgid = 234
                        elif mode == 'volatile' and children == 2:
                            pointer._obj.nfiles = 1
                    elif mode == 'parent' and children == 2:
                        pointer._obj.seconds = 200
                    return result

                with patch.object(self.kernel, 'proc_pidinfo', side_effect=record) as reads:
                    self.assertFalse(owner.terminal_child(234, 123, owner.known[123]))
                row = owner.terminal_child_refusals[234]
                self.assertEqual(row['terminalRefusalReason'], {
                    'group': 'first_child_record', 'volatile': 'child_records_changed',
                    'parent': 'parent_after',
                }[mode])
                self.assertTrue(row['terminalChildRecordComplete'])
                self.assertTrue(row['terminalChildIsZombie'])
                self.assertEqual(row['terminalChildGroupMatchesParent'], mode != 'group')
                self.assertEqual(row['terminalRawRecordsStable'], None if mode == 'group' else mode == 'parent')
                self.assertEqual(reads.call_count, {'group': 3, 'volatile': 6, 'parent': 5}[mode])
                self.assertEqual(owner.terminal_children, {})
                self.assertNotIn(234, owner.known)
                self.assertNotIn(234, owner.seals)
        self.assertEqual(self.kernel.signals, [])

    def test_refusal_rows_are_closed_bounded_first_seen_and_never_expose_paths(self):
        for pid in range(234, 246):
            self.assertFalse(self.owner.terminal_child_refusal(
                pid, 123, self.owner.known[123], '/fixture/private-reason', stable='private-value'))
        self.assertEqual(len(self.owner.terminal_child_refusals), 8)
        original = dict(self.owner.terminal_child_refusals[234])
        self.owner.terminal_child_refusal(234, 123, self.owner.known[123], 'parent_before')
        self.assertEqual(self.owner.terminal_child_refusals[234], original)
        self.owner.observe_failure(234, 'live_identity_unavailable')
        row = self.owner.failure_observations[0]
        self.assertEqual(row['terminalRefusalReason'], 'unknown')
        self.assertIsNone(row['terminalRawRecordsStable'])
        self.assertNotIn('private', json.dumps(row))
        self.assertTrue(all(type(value) is bool or value is None
                            for key, value in original.items()
                            if key not in ['terminalRefusalReason', 'terminalChildRole']))
        self.assertEqual(self.owner.terminal_children, {})
        self.assertEqual(self.kernel.signals, [])

    def test_recovery_stage_survives_saturated_history_without_changing_kernel_calls(self):
        self.owner.recovery_failure_stages = {pid: 'first_kernel' for pid in range(400, 408)}
        original = self.kernel.proc_pidinfo
        calls = 0

        def record(pid, flavor, argument, pointer, size):
            nonlocal calls
            calls += 1
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return 0 if calls <= 2 else result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record) as reads:
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(123)
        self.assertEqual([call.args[:3] for call in reads.call_args_list],
                         [(123, 3, 0), (123, 3, 0), (123, 3, 1), (123, 3, 1)])
        row = self.owner.failure_observations[0]
        self.assertNotIn('recoveryFailureStage', row)
        self.assertEqual(row['recoveryProofStage'], 'first_kernel')
        self.assertEqual(row['status'], 2)
        self.assertTrue(row['knownSeal'])
        self.assertEqual(len(self.owner.recovery_failure_stages), 8)
        self.assertEqual(self.owner.private_failure_pid_roles, {123: 'leader'})
        self.assertNotIn('pid', row)
        self.assertEqual(self.kernel.signals, [])

    def test_path_refusal_cannot_reuse_a_previous_kernel_recovery_reason(self):
        self.owner.last_recovery_failure = (123, 'first_kernel')
        original = self.kernel.proc_pidinfo

        def record(pid, flavor, argument, pointer, size):
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record) as reads, \
                patch.object(self.kernel, 'proc_pidpath', return_value=0):
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(123)
        self.assertEqual([call.args[:3] for call in reads.call_args_list],
                         [(123, 3, 0), (123, 3, 1), (123, 3, 1)])
        self.assertEqual(self.owner.failure_observations[0]['recoveryProofStage'], 'not_attempted')
        self.assertEqual(self.owner.private_failure_pid_roles, {123: 'leader'})
        self.assertEqual(self.kernel.signals, [])

    def test_failure_pid_roles_are_only_in_private_timeline_after_original_join(self):
        clock = Clock()
        process = Process(0)
        ownership = Ownership(process)
        ownership.private_failure_pid_roles = {123: 'leader', 234: 'unsealed'}
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as directory:
            result = runner.run_original(
                ['synthetic-command'], Path(directory), {}, Path(directory),
                process_factory=lambda *args, **kwargs: process,
                ownership_factory=lambda *args: ownership, clock=clock.now, sleep=clock.sleep)
            rows = [json.loads(line) for line in (Path(directory) / 'processes.jsonl').read_text().splitlines()]
        self.assertFalse(result['passed'])
        self.assertFalse(result['testsCompleted'])
        self.assertEqual(rows[-1], {'failurePIDRoles': [
            {'pid': 123, 'role': 'leader'}, {'pid': 234, 'role': 'unsealed'},
        ]})
        self.assertNotIn('failurePIDRoles', result)
        self.assertNotIn('private_failure_pid_roles', result)
        self.assertEqual(process.reaps, 1)
        self.assertEqual(ownership.signals, [])

    def test_successful_recovery_clears_terminal_refusal_before_later_path_failure(self):
        original = self.kernel.proc_pidinfo
        calls = 0

        def record(pid, flavor, argument, pointer, size):
            nonlocal calls
            calls += 1
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            return 0 if calls == 1 else result

        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record):
            self.assertEqual(self.owner.snapshot(123)[:5], self.owner.known[123])
        self.assertIsNone(self.owner.last_recovery_failure)
        self.assertEqual(self.owner.terminal_child_refusals, {})
        with patch.object(self.kernel, 'proc_pidinfo', side_effect=record), \
                patch.object(self.kernel, 'proc_pidpath', return_value=0):
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable'):
                self.owner.snapshot(123)
        row = self.owner.failure_observations[0]
        self.assertEqual(row['recoveryProofStage'], 'not_attempted')
        self.assertNotIn('terminalRefusalReason', row)
        self.assertEqual(self.kernel.signals, [])


if __name__ == '__main__':
    unittest.main()
