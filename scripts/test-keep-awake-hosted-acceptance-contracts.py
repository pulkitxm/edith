from pathlib import Path
from contextlib import redirect_stdout
import importlib.util
import io
import json
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'keep_awake_acceptance', Path(__file__).with_name('test-keep-awake-hosted-acceptance.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceContracts(unittest.TestCase):
    def hosted_environment(self):
        return {
            'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
            'RUNNER_OS': 'macOS', 'GITHUB_REPOSITORY': 'pulkitxm/edith',
            'GITHUB_REPOSITORY_ID': '1289153439', 'GITHUB_ACTOR_ID': '65671483',
            'GITHUB_REF': 'refs/heads/fix/keep-awake-accessibility-action',
            'GITHUB_EVENT_NAME': 'workflow_dispatch', 'EXTENSION_PUBLISH': 'false',
            'EXPECTED_SOURCE_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40,
        }

    def test_exact_nonpublishing_preview_keeps_checkout_identity_and_cleanliness_checks(self):
        environment = self.hosted_environment()
        root = Path('/synthetic/checkout')
        with patch.object(acceptance.subprocess, 'check_output',
                          side_effect=['a' * 40 + '\n', '']) as lookup:
            self.assertEqual(acceptance.admit_source(environment, root), 'a' * 40)
        self.assertEqual(lookup.call_args_list[0].args[0], ['git', 'rev-parse', 'HEAD'])
        self.assertEqual(lookup.call_args_list[1].args[0],
                         ['git', 'status', '--porcelain', '--untracked-files=no'])
        self.assertTrue(all(call.kwargs == {'cwd': root, 'text': True}
                            for call in lookup.call_args_list))

    def test_only_exact_manual_nonpublishing_preview_ref_is_added(self):
        cases = [
            ('refs/heads/main', 'push', 'true', True),
            ('refs/heads/feat/extension-marketplace', 'workflow_dispatch', 'false', True),
            ('refs/heads/fix/keep-awake-accessibility-action', 'workflow_dispatch', 'false', True),
            ('refs/heads/fix/keep-awake-accessibility-action', 'push', 'false', False),
            ('refs/heads/fix/keep-awake-accessibility-action', 'pull_request', 'false', False),
            ('refs/heads/fix/keep-awake-accessibility-action', 'workflow_dispatch', 'true', False),
            ('refs/heads/fix/keep-awake-accessibility-action', 'workflow_dispatch', None, False),
            ('refs/heads/fix/keep-awake-accessibility-action', 'workflow_dispatch', '', False),
            ('refs/heads/fix/keep-awake-accessibility-action', 'workflow_dispatch', 'False', False),
            ('refs/heads/fix/extension-peer-unix', 'workflow_dispatch', 'false', False),
            ('refs/heads/fix/keep-awake-accessibility-action-extra', 'workflow_dispatch', 'false', False),
            ('refs/pull/1371/merge', 'workflow_dispatch', 'false', False),
        ]
        for ref, event, publication, admitted in cases:
            with self.subTest(ref=ref, event=event, publication=publication):
                environment = {**self.hosted_environment(), 'GITHUB_REF': ref,
                               'GITHUB_EVENT_NAME': event, 'EXTENSION_PUBLISH': publication}
                with patch.object(acceptance.subprocess, 'check_output',
                                  side_effect=['a' * 40 + '\n', '']):
                    if admitted:
                        self.assertEqual(acceptance.admit_source(environment, Path('/synthetic')),
                                         'a' * 40)
                    else:
                        with self.assertRaisesRegex(ValueError, 'Unreviewed source ref'):
                            acceptance.admit_source(environment, Path('/synthetic'))

    def test_preview_cannot_bypass_host_repository_actor_or_full_source_guards(self):
        changes = [
            {'GITHUB_ACTIONS': 'false'}, {'RUNNER_ENVIRONMENT': 'self-hosted'},
            {'RUNNER_OS': 'Linux'}, {'GITHUB_REPOSITORY': 'synthetic/other'},
            {'GITHUB_REPOSITORY_ID': '1'}, {'GITHUB_ACTOR_ID': '1'},
            {'EXPECTED_SOURCE_SHA': 'a' * 39}, {'EXPECTED_SOURCE_SHA': 'a' * 41},
            {'EXPECTED_SOURCE_SHA': 'A' * 40, 'GITHUB_SHA': 'A' * 40},
            {'EXPECTED_SOURCE_SHA': 'g' * 40, 'GITHUB_SHA': 'g' * 40},
            {'GITHUB_SHA': 'b' * 40},
        ]
        for changed in changes:
            with self.subTest(changed=changed):
                with patch.object(acceptance.subprocess, 'check_output') as lookup:
                    with self.assertRaises(ValueError):
                        acceptance.admit_source({**self.hosted_environment(), **changed},
                                                Path('/synthetic'))
                lookup.assert_not_called()

    def test_preview_rejects_changed_head_and_tracked_source(self):
        for head, status, message in [('b' * 40, '', 'Checkout source mismatch'),
                                     ('a' * 40, ' M synthetic.swift', 'Tracked source is dirty')]:
            with self.subTest(message=message):
                with patch.object(acceptance.subprocess, 'check_output', side_effect=[head, status]):
                    with self.assertRaisesRegex(ValueError, message):
                        acceptance.admit_source(self.hosted_environment(), Path('/synthetic'))

    def failed_runner(self):
        return {
            'passed': False, 'exitCode': 7, 'timedOut': False,
            'logBoundExceeded': False, 'failure': 'synthetic failure',
            'testsCompleted': False, 'observedTestingProcess': True,
            'privateField': 'must not be logged',
            'cleanup': {'naturalSurvivorCount': 0, 'reaped': True,
                        'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0,
                        'ownershipErrors': ['private ownership detail']},
        }

    def test_native_failure_emits_closed_metadata_without_private_details(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'tests.log'
            log.write_text('synthetic XCTest rejection\n')
            captured = io.StringIO()
            with redirect_stdout(captured):
                acceptance.native_failure_diagnostics(self.failed_runner(), log)
            rows = [json.loads(line) for line in captured.getvalue().splitlines()]
            self.assertEqual(len(rows), 2)
            self.assertEqual(set(rows[0]), {'nativeFailure'})
            metadata = rows[0]['nativeFailure']
            self.assertEqual(set(metadata), {'exitCode', 'timedOut', 'logBoundExceeded',
                             'failure', 'testsCompleted', 'observedTestingProcess', 'cleanup'})
            self.assertEqual(metadata['exitCode'], 7)
            self.assertEqual(metadata['failure'], 'synthetic failure')
            self.assertEqual(metadata['cleanup'], {'naturalSurvivorCount': 0, 'reaped': True,
                             'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0,
                             'ownershipErrorCount': 1})
            self.assertEqual(rows[1], {'nativeLogTail': 'synthetic XCTest rejection\n'})
            self.assertNotIn('private', captured.getvalue())

    def test_native_failure_tail_is_bounded_and_stdout_commands_are_escaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'tests.log'
            for payload in [b'x' * 32768, ('\u2603' * 12000).encode(), b'\xff' * 32768]:
                ending = b'\n::error::synthetic final assertion\n'
                log.write_bytes(b'excluded synthetic prefix\n' + payload + ending)
                captured = io.StringIO()
                with redirect_stdout(captured):
                    acceptance.native_failure_diagnostics(self.failed_runner(), log)
                rows = captured.getvalue().splitlines()
                self.assertEqual(len(rows), 2)
                tail = json.loads(rows[1])['nativeLogTail']
                self.assertLessEqual(len(tail.encode('utf-8')), 16384)
                self.assertTrue(tail.endswith(ending.decode()))
                self.assertNotIn('excluded synthetic prefix', tail)
                self.assertTrue(all(line.startswith('{') for line in rows))

    def test_native_success_emits_nothing_and_does_not_require_a_log(self):
        captured = io.StringIO()
        with redirect_stdout(captured):
            acceptance.native_failure_diagnostics({'passed': True}, Path('missing-tests.log'))
        self.assertEqual(captured.getvalue(), '')

    def captured_snapshot(self):
        return {
            'clause': 'executable_path_unavailable', 'returnedBytes': 136,
            'expectedBytes': 136, 'status': 2, 'pidMatches': True,
            'birthMatches': None, 'groupMatches': None, 'uidMatches': True,
            'realUIDMatches': True, 'parentEnumerated': True,
            'parentIdentityKnown': True, 'parentMatches': True, 'leaderGroupMatches': True,
        }

    def captured_diagnostics(self, candidates, errors=None, passed=False):
        value = self.failed_runner()
        value['passed'] = passed
        value['capturedSnapshotFailures'] = candidates
        value['cleanup']['ownershipErrors'] = errors or ['Live owned process identity unavailable']
        output = io.StringIO()
        with redirect_stdout(output):
            acceptance.native_failure_diagnostics(value, Path('missing-tests.log'))
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_original_snapshot_diagnostics_are_closed_bounded_and_failure_only(self):
        row = self.captured_snapshot()
        rows = self.captured_diagnostics([row] * 12)
        self.assertEqual(rows[-1], {'nativeOwnershipCapturedSnapshotFailures': [row] * 8})
        self.assertEqual(rows[2], {'nativeOwnershipFailureKinds': ['live_identity_unavailable']})
        self.assertEqual(self.captured_diagnostics([row], passed=True), [])
        unknown = self.captured_diagnostics([row], errors=['private ownership detail'])
        self.assertEqual(len(unknown), 2)
        self.assertNotIn('private', json.dumps(unknown))

    def test_original_snapshot_diagnostics_reject_unknown_fields_and_invalid_metadata(self):
        row = self.captured_snapshot()
        changes = [
            {'clause': '/fixture/private/token'}, {'clause': {'private': 'token'}},
            {'pid': 987}, {'status': True},
            {'returnedBytes': True}, {'returnedBytes': 2**32}, {'expectedBytes': 0},
            {'parentEnumerated': 1}, {'uidMatches': 'private'}, {'parentMatches': 1},
        ]
        for change in changes:
            with self.subTest(change=change):
                rows = self.captured_diagnostics([{**row, **change}, row])
                self.assertEqual(rows[-1], {'nativeOwnershipCapturedSnapshotFailures': [row]})
                self.assertNotIn('private', json.dumps(rows))
        self.assertEqual(len(self.captured_diagnostics('private')), 3)

    def ownership_diagnostics(self, errors, passed=False):
        value = self.failed_runner()
        value['passed'] = passed
        value['cleanup']['ownershipErrors'] = errors
        captured = io.StringIO()
        with redirect_stdout(captured):
            acceptance.native_failure_diagnostics(value, Path('missing-tests.log'))
        return [json.loads(line) for line in captured.getvalue().splitlines()]

    def test_known_live_identity_failure_emits_only_closed_category(self):
        rows = self.ownership_diagnostics(['Live owned process identity unavailable'])
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]['nativeFailure']['cleanup']['ownershipErrorCount'], 1)
        self.assertEqual(rows[1], {'nativeLogTail': ''})
        self.assertEqual(rows[2], {'nativeOwnershipFailureKinds': ['live_identity_unavailable']})
        self.assertNotIn('Live owned process', json.dumps(rows))

    def test_known_birth_and_group_failures_keep_distinct_categories(self):
        rows = self.ownership_diagnostics(['Owned process birth or group changed',
                                          'Owned leader group changed'])
        self.assertEqual(rows[0]['nativeFailure']['cleanup']['ownershipErrorCount'], 2)
        self.assertEqual(rows[2], {'nativeOwnershipFailureKinds':
                         ['birth_or_group_changed', 'leader_group_changed']})

    def test_unknown_errors_are_filtered_and_known_categories_are_deduplicated(self):
        private = '/fixture/private-home/secret-token pid=987 environment=private'
        known = ['Live owned process identity unavailable',
                 'Owned process birth or group changed',
                 'Owned leader group changed',
                 'Owned descendant parent changed',
                 'Owned parent identity changed before admission',
                 'Owned lifetime process bound exceeded',
                 'Owned executable transition bound exceeded',
                 'Owned concurrent descendant bound exceeded',
                 'Invalid owned child enumeration',
                 'Owned identity changed before signal']
        rows = self.ownership_diagnostics(known * 4 + [private, known[0] + private, None, {}])
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]['nativeFailure']['cleanup']['ownershipErrorCount'], 44)
        self.assertEqual(rows[2], {'nativeOwnershipFailureKinds': sorted([
            'live_identity_unavailable', 'birth_or_group_changed', 'leader_group_changed',
            'descendant_parent_changed', 'parent_identity_changed',
            'lifetime_process_bound_exceeded', 'executable_transition_bound_exceeded',
            'concurrent_descendant_bound_exceeded', 'child_enumeration_invalid',
            'identity_changed_before_signal'])})
        self.assertEqual(len(rows[2]['nativeOwnershipFailureKinds']), 10)
        self.assertNotIn(private, json.dumps(rows))
        self.assertEqual(len(self.ownership_diagnostics([private, known[0] + private])), 2)

    def test_success_with_known_ownership_errors_emits_nothing(self):
        self.assertEqual(self.ownership_diagnostics(
            ['Live owned process identity unavailable', 'Owned process birth or group changed'],
            passed=True), [])

    def failure_observation(self):
        return {
            'kind': 'live_identity_unavailable', 'knownSeal': True,
            'originalBirthMatches': None, 'originalGroupMatches': None,
            'returnedBytes': 128, 'expectedBytes': 128, 'status': 5,
            'pidMatches': True, 'birthMatches': True, 'groupMatches': True,
            'uidMatches': True, 'realUIDMatches': True, 'probeFailed': False,
        }

    def observations_diagnostics(self, observations, errors=None, passed=False):
        value = self.failed_runner()
        value['passed'] = passed
        value['ownershipFailureObservations'] = observations
        value['cleanup']['ownershipErrors'] = errors or ['Live owned process identity unavailable']
        captured = io.StringIO()
        with redirect_stdout(captured):
            acceptance.native_failure_diagnostics(value, Path('missing-tests.log'))
        return captured.getvalue()

    def test_known_numeric_observations_emit_after_unchanged_category_rows(self):
        row = self.failure_observation()
        text = self.observations_diagnostics([row])
        rows = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[2], {'nativeOwnershipFailureKinds': ['live_identity_unavailable']})
        self.assertEqual(rows[3], {'nativeOwnershipFailureObservations': [row]})
        self.assertNotIn('private', text)

    def test_numeric_observations_reject_unknown_fields_and_non_numeric_values(self):
        for changes in [{'pid': 987}, {'path': '/fixture/private'}, {'status': 'private'},
                        {'status': True}, {'kind': 'private'}, {'birthMatches': 1},
                        {'returnedBytes': 2147483648}, {'expectedBytes': 4097},
                        {'status': 4294967296}, {'knownSeal': 1}]:
            with self.subTest(changes=changes):
                row = {**self.failure_observation(), **changes}
                text = self.observations_diagnostics([row])
                self.assertEqual(len(text.splitlines()), 3)
                self.assertNotIn('private', text)
        text = self.observations_diagnostics([self.failure_observation()],
                                             errors=['private ownership detail'])
        self.assertEqual(len(text.splitlines()), 2)
        self.assertNotIn('nativeOwnershipFailureObservations', text)

    def test_numeric_observation_output_is_bounded_and_success_emits_nothing(self):
        row = self.failure_observation()
        text = self.observations_diagnostics([row] * 20)
        rows = text.splitlines()
        self.assertEqual(len(json.loads(rows[3])['nativeOwnershipFailureObservations']), 8)
        self.assertLessEqual(len(rows[3].encode()), 4096)
        self.assertEqual(self.observations_diagnostics([row], passed=True), '')

    def native(self):
        return {
            'schema': 1, 'sourceCommit': 'a' * 40, 'owner': 'keepAwake',
            'originalCheckboxActivated': True, 'productionRuntimeInvoked': True,
            'realIOKitAssertionVerified': True, 'shutdownAssertionReleased': True,
            'requestedPreferencePreserved': True, 'transitions': [True, False, True],
            'syntheticPlatformAdapter': False, 'workerProcessLifecycleVerified': False,
        }

    def worker(self):
        return {
            'id': 'keepAwake', 'downloadedBundle': True, 'headlessLifecycle': True,
            'engineLifecycleValidated': True, 'updateWithoutAppRestart': True,
            'restoreAfterAppUpdate': True, 'freshHostSessionRestored': True,
            'pendingDisableRecoveryValidated': True, 'removedPayloads': True,
            'isolatedSupportTypes': True, 'surfaceLayoutRestored': True,
            'surfaceDataValidated': True, 'disabledProcesses': 0,
            'nativeWindow': False, 'managedNativeViewValidated': False,
        }

    def test_accepts_complete_independent_native_and_worker_results(self):
        acceptance.native_proof(self.native(), 'a' * 40)
        acceptance.lifecycle_proof(self.worker())

    def test_rejects_wrong_source_and_foreign_owner(self):
        with self.assertRaises(ValueError):
            acceptance.native_proof(self.native(), 'b' * 40)
        result = self.worker()
        result['id'] = 'terminal'
        with self.assertRaises(ValueError):
            acceptance.lifecycle_proof(result)

    def test_rejects_each_missing_native_outcome(self):
        for field in ['originalCheckboxActivated', 'productionRuntimeInvoked',
                      'realIOKitAssertionVerified', 'shutdownAssertionReleased',
                      'requestedPreferencePreserved']:
            result = self.native()
            result.pop(field)
            with self.subTest(field=field), self.assertRaises(ValueError):
                acceptance.native_proof(result, 'a' * 40)

    def test_rejects_synthetic_assertions_and_incomplete_toggles(self):
        for field, value in [('syntheticPlatformAdapter', True),
                             ('workerProcessLifecycleVerified', True),
                             ('transitions', [True, False])]:
            result = self.native()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                acceptance.native_proof(result, 'a' * 40)

    def test_rejects_worker_survivors_and_missing_update(self):
        for field, value in [('disabledProcesses', 1), ('updateWithoutAppRestart', False),
                             ('pendingDisableRecoveryValidated', False), ('removedPayloads', False)]:
            result = self.worker()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                acceptance.lifecycle_proof(result)

    def test_rejects_worker_claiming_native_ui(self):
        for field in ['nativeWindow', 'managedNativeViewValidated']:
            result = self.worker()
            result[field] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                acceptance.lifecycle_proof(result)

    def test_private_output_rejects_symlink_and_public_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            acceptance.private_directory(root, private=True)
            link = root / 'link'
            link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                acceptance.private_directory(link, private=True)
            root.chmod(0o755)
            with self.assertRaises(ValueError):
                acceptance.private_directory(root, private=True)


    def worker_runner(self):
        value = self.failed_runner()
        value.update(passed=False, exitCode=0, failure=None, testsCompleted=False,
                     observedTestingProcess=False)
        value['cleanup']['ownershipErrors'] = []
        return value

    def worker_diagnostics(self, value):
        captured = io.StringIO()
        with redirect_stdout(captured):
            acceptance.worker_failure_diagnostics(value)
        return captured.getvalue()

    def test_clean_worker_emits_nothing_without_requiring_testing_process_or_test_markers(self):
        self.assertEqual(self.worker_diagnostics(self.worker_runner()), '')

    def test_each_worker_cleanup_rejection_emits_its_actual_condition_without_changing_outcome(self):
        for field, value, nested in [
            ('exitCode', 17, False), ('timedOut', True, False),
            ('logBoundExceeded', True, False), ('failure', 'private secret', False),
            ('naturalSurvivorCount', 1, True), ('reaped', False, True),
            ('remainingOwnedProcesses', 1, True), ('unverifiedOwnedProcesses', 1, True),
            ('ownershipErrors', ['Live owned process identity unavailable'], True),
        ]:
            with self.subTest(field=field):
                result = self.worker_runner()
                (result['cleanup'] if nested else result)[field] = value
                before = json.dumps(result, sort_keys=True)
                text = self.worker_diagnostics(result)
                row = json.loads(text)['workerFailure']
                self.assertEqual(json.dumps(result, sort_keys=True), before)
                self.assertEqual(len(text.splitlines()), 1)
                if field == 'failure':
                    self.assertTrue(row['failurePresent'])
                elif field == 'ownershipErrors':
                    self.assertEqual(row['cleanup']['ownershipErrorCount'], 1)
                    self.assertEqual(row['ownershipFailureKinds'], ['live_identity_unavailable'])
                elif nested:
                    self.assertEqual(row['cleanup'][field], value)
                else:
                    self.assertEqual(row[field], value)
                self.assertNotIn('private', text)

    def test_worker_failure_metadata_is_closed_bounded_and_cannot_expose_freeform_receipts(self):
        result = self.worker_runner()
        private = '/private/home/secret-token ::error::private'
        result.update(failure=private * 10000, argv=[private], privateField=private,
                      ownedExecutableTransitions=[private], knownOwnedProcesses=[private])
        result['cleanup'].update(ownershipErrors=[private] * 4096 + [
            'Owned process birth or group changed', 'Owned process birth or group changed'],
            privateField=private)
        text = self.worker_diagnostics(result)
        row = json.loads(text)['workerFailure']
        self.assertEqual(set(row), {'exitCode', 'timedOut', 'logBoundExceeded',
                         'failurePresent', 'harnessSignal', 'harnessStage', 'testsCompleted',
                         'observedTestingProcess', 'cleanup', 'ownershipFailureKinds'})
        self.assertEqual(set(row['cleanup']), {'naturalSurvivorCount', 'reaped',
                         'remainingOwnedProcesses', 'unverifiedOwnedProcesses', 'ownershipErrorCount'})
        self.assertEqual(row['cleanup']['ownershipErrorCount'], 4098)
        self.assertEqual(row['ownershipFailureKinds'], ['birth_or_group_changed'])
        self.assertLess(len(text.encode()), 1024)
        self.assertNotIn('private', text)
        self.assertNotIn('secret-token', text)
        self.assertNotIn('::error::', text)

    def test_worker_diagnostics_filter_untyped_or_unbounded_fields(self):
        result = self.worker_runner()
        result.update(exitCode='private', timedOut='private', logBoundExceeded=1,
                      testsCompleted='private', observedTestingProcess=1)
        result['cleanup'].update(naturalSurvivorCount=True, reaped='private',
                                remainingOwnedProcesses=2**32, unverifiedOwnedProcesses='private')
        row = json.loads(self.worker_diagnostics(result))['workerFailure']
        for field in ['exitCode', 'timedOut', 'logBoundExceeded',
                      'testsCompleted', 'observedTestingProcess']:
            self.assertIsNone(row[field])
        for field in ['naturalSurvivorCount', 'reaped', 'remainingOwnedProcesses',
                      'unverifiedOwnedProcesses']:
            self.assertIsNone(row['cleanup'][field])
        self.assertNotIn('private', json.dumps(row))

    def test_actual_worker_diagnostic_call_precedes_unchanged_acceptance_rejection(self):
        source = Path(acceptance.__file__).read_text()
        call = source.index("        worker_failure_diagnostics(worker, work / 'worker/tests.log')")
        rejection = source.index("        require(worker['exitCode'] == 0")
        self.assertLess(call, rejection)
        self.assertIn("and cleanup['unverifiedOwnedProcesses'] == 0 and not cleanup['ownershipErrors']", source)



    def test_worker_harness_signal_projection_is_bounded_closed_and_omits_process_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'worker.log'
            failure = {'signal': 'SIGBUS', 'pid': 987654, 'source': 'a' * 40,
                       'stage': 'packageStoreBegin'}
            valid = json.dumps({'lifecycleHarnessFailure': failure})
            private = '/private/home/secret-token ::error::private'
            log.write_text(private * 2000 + '\n' + valid + '\n' + json.dumps({
                'lifecycleHarnessFailure': {**failure, 'stage': private}}) + '\n')
            captured = io.StringIO()
            result = self.worker_runner()
            result['exitCode'] = 1
            with redirect_stdout(captured):
                acceptance.worker_failure_diagnostics(result, log)
            text = captured.getvalue()
            row = json.loads(text)['workerFailure']
            self.assertEqual(row['harnessSignal'], 'SIGBUS')
            self.assertEqual(row['harnessStage'], 'packageStoreBegin')
            for value in [private, '987654', 'a' * 40, '::error::']:
                self.assertNotIn(value, text)
            self.assertLess(len(text.encode()), 1024)
            for edit in [{'extra': private}, {'signal': private}, {'signal': {}},
                         {'pid': True}, {'source': private}, {'stage': {}}]:
                log.write_text(json.dumps({'lifecycleHarnessFailure': {**failure, **edit}}))
                captured = io.StringIO()
                with redirect_stdout(captured):
                    acceptance.worker_failure_diagnostics(result, log)
                row = json.loads(captured.getvalue())['workerFailure']
                self.assertIsNone(row['harnessSignal'])
                self.assertIsNone(row['harnessStage'])
            captured = io.StringIO()
            with patch.object(Path, 'open', side_effect=AssertionError('clean worker opened log')):
                with redirect_stdout(captured):
                    acceptance.worker_failure_diagnostics(self.worker_runner(), log)
            self.assertEqual(captured.getvalue(), '')



    def real_self_group_failure(self):
        module_spec = importlib.util.spec_from_file_location(
            'ownership_contract_fixtures', Path(__file__).with_name('test-hosted-native-owner-tests.py'))
        fixtures = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(fixtures)
        product = fixtures.runner
        kernel = fixtures.Kernel()
        kernel.processes[234] = (234, 101, 8, '/synthetic/original', 123, 123, 501, 501)
        original = kernel.proc_pidinfo

        def live(pid, flavor, argument, pointer, size):
            result = original(pid, flavor, argument, pointer, size)
            if result == size:
                pointer._obj.status = 2
            return result

        kernel.proc_pidinfo = live
        with patch.object(product.watchdog.ctypes, 'CDLL', return_value=kernel), \
                patch.object(product.os, 'kill', side_effect=kernel.kill):
            owner = product.BoundedOwnership(123, 501)
            owner.refresh()
            self.assertEqual(owner.errors, [])
            kernel.processes[234] = (234, 101, 8, '/synthetic/changed', 234, 123, 501, 501)
            owner.refresh()
        self.assertEqual(owner.errors, ['Owned process birth or group changed'])
        self.assertEqual(kernel.signals, [])
        value = self.failed_runner()
        value['cleanup']['ownershipErrors'] = owner.errors
        value['cleanup']['unverifiedOwnedProcesses'] = len(owner.conflicts())
        value['ownershipFailureObservations'] = owner.failure_observations
        return value, owner

    def emitted_group_rows(self, value):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'synthetic.log'
            log.write_text('synthetic original failure\n')
            output = io.StringIO()
            with redirect_stdout(output):
                acceptance.native_failure_diagnostics(value, log)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        return [row['nativeOwnershipFailureObservations'] for row in rows
                if 'nativeOwnershipFailureObservations' in row], output.getvalue()

    def test_real_owned_self_group_failure_survives_current_closed_diagnostic_boundary(self):
        value, owner = self.real_self_group_failure()
        rows, text = self.emitted_group_rows(value)
        self.assertEqual(rows, [owner.failure_observations])
        self.assertEqual(len(rows[0]), 1)
        row = rows[0][0]
        self.assertEqual(row['kind'], 'birth_or_group_changed')
        self.assertTrue(row['knownChild'])
        self.assertTrue(row['groupIsOwnPID'])
        self.assertTrue(row['originalParentRetained'])
        self.assertFalse(row['currentPathMatchesRetained'])
        self.assertFalse(row['transitionAdmitted'])
        self.assertNotIn('/synthetic/', text)
        self.assertNotIn('pid": 234', text)

    def test_self_group_extension_rejects_missing_extra_and_nonboolean_fields(self):
        value, _ = self.real_self_group_failure()
        original = value['ownershipFailureObservations'][0]
        for field in ['knownChild', 'groupIsOwnPID', 'originalParentRetained',
                      'currentPathMatchesRetained', 'twoChildRecordsMatch', 'parentBeforeMatches',
                      'parentAfterMatches', 'parentRecordsStable', 'transitionAdmitted']:
            for malformed in ['missing', 'integer', 'null', 'string']:
                with self.subTest(field=field, malformed=malformed):
                    row = dict(original)
                    if malformed == 'missing':
                        row.pop(field)
                    else:
                        row[field] = {'integer': 1, 'null': None, 'string': '/synthetic/private'}[malformed]
                    value['ownershipFailureObservations'] = [row]
                    rows, text = self.emitted_group_rows(value)
                    self.assertEqual(rows, [])
                    self.assertNotIn('/synthetic/private', text)
        for update in [{'extra': True}, {'kind': 'live_identity_unavailable'}]:
            row = {**original, **update}
            value['cleanup']['ownershipErrors'] = ['Live owned process identity unavailable',
                                                   'Owned process birth or group changed']
            value['ownershipFailureObservations'] = [row]
            rows, _ = self.emitted_group_rows(value)
            self.assertEqual(rows, [])

    def test_ordinary_live_failure_does_not_reuse_stale_self_group_observations(self):
        _, owner = self.real_self_group_failure()
        owner.observe_failure(234, 'live_identity_unavailable')
        row = owner.failure_observations[-1]
        self.assertEqual(row['kind'], 'live_identity_unavailable')
        self.assertNotIn('knownChild', row)
        self.assertNotIn('transitionAdmitted', row)
        value = self.failed_runner()
        value['cleanup']['ownershipErrors'] = ['Live owned process identity unavailable']
        value['ownershipFailureObservations'] = [row]
        rows, _ = self.emitted_group_rows(value)
        self.assertEqual(rows, [[row]])


    def real_known_recovery_failure(self, stage, product=None):
        module_spec = importlib.util.spec_from_file_location(
            'recovery_contract_fixtures', Path(__file__).with_name('test-hosted-native-owner-tests.py'))
        fixtures = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(fixtures)
        product = product or fixtures.runner
        kernel = fixtures.Kernel()
        original_info = kernel.proc_pidinfo
        original_path = kernel.proc_pidpath
        trace = []
        readings = 0
        paths = 0
        active = False

        def record(pid, flavor, argument, pointer, size):
            nonlocal readings
            result = original_info(pid, flavor, argument, pointer, size)
            pointer._obj.status = 2
            if active:
                readings += 1
                if readings == 1 or stage == 'first_kernel' and readings == 2 \
                        or stage == 'second_kernel' and readings == 3:
                    result = 0
                if stage == 'snapshot_fields' and readings == 3:
                    pointer._obj.ppid += 1
                trace.append(('kernel', pid, flavor, argument, result))
            return result

        def path(pid, buffer, size):
            nonlocal paths
            result = original_path(pid, buffer, size)
            if active:
                paths += 1
                if stage == 'first_path' and paths == 1 or stage == 'second_path' and paths == 2:
                    result = 0
                trace.append(('path', pid, result))
            return result

        kernel.proc_pidinfo = record
        kernel.proc_pidpath = path
        with patch.object(product.watchdog.ctypes, 'CDLL', return_value=kernel), \
                patch.object(product.os, 'kill', side_effect=kernel.kill):
            owner = product.BoundedOwnership(123, 501)
            original_seals = dict(owner.seals)
            if stage == 'retained_identity':
                identity = owner.known[123]
                owner.known[123] = (123, 200, *identity[2:])
            active = True
            self.assertEqual(owner.refresh(), [])
        self.assertEqual(owner.errors, ['Live owned process identity unavailable'])
        self.assertEqual(owner.seals, original_seals)
        self.assertEqual(kernel.signals, [])
        value = self.failed_runner()
        value['cleanup']['ownershipErrors'] = owner.errors
        value['cleanup']['unverifiedOwnedProcesses'] = len(owner.conflicts())
        value['ownershipFailureObservations'] = owner.failure_observations
        return value, owner, trace

    def test_existing_recovery_reads_emit_only_the_closed_actual_failed_stage(self):
        for stage in ['retained_identity', 'first_kernel', 'first_path', 'second_kernel',
                      'second_path', 'snapshot_fields']:
            with self.subTest(stage=stage):
                value, owner, _ = self.real_known_recovery_failure(stage)
                rows, text = self.emitted_group_rows(value)
                self.assertEqual(rows, [owner.failure_observations])
                self.assertEqual(rows[0][0]['recoveryFailureStage'], stage)
                self.assertEqual(rows[0][0]['kind'], 'live_identity_unavailable')
                self.assertTrue(rows[0][0]['knownSeal'])
                self.assertNotIn('/usr/bin/make', text)
                self.assertNotIn('pid": 123', text)

    def test_recovery_stage_rejects_unknown_nonstring_extra_and_unrelated_kind_fields(self):
        value, _, _ = self.real_known_recovery_failure('first_kernel')
        original = value['ownershipFailureObservations'][0]
        for stage in [None, True, 1, '/synthetic/private', 'unknown']:
            with self.subTest(stage=stage):
                value['ownershipFailureObservations'] = [{**original, 'recoveryFailureStage': stage}]
                rows, text = self.emitted_group_rows(value)
                self.assertEqual(rows, [])
                self.assertNotIn('/synthetic/private', text)
        for update in [{'extra': True}, {'kind': 'birth_or_group_changed'}, {'knownChild': True}]:
            value['cleanup']['ownershipErrors'] = ['Live owned process identity unavailable',
                                                   'Owned process birth or group changed']
            value['ownershipFailureObservations'] = [{**original, **update}]
            rows, _ = self.emitted_group_rows(value)
            self.assertEqual(rows, [])

    def test_recovery_stage_storage_and_emission_stay_bounded(self):
        _, owner, _ = self.real_known_recovery_failure('first_path')
        for pid in range(200, 220):
            owner.known[pid] = (pid, 100, 1, '/synthetic/path', 123)
            owner.seals[pid] = (pid, 100, 1, 123)
            self.assertIsNone(owner.record_recovery_failure(pid, 'first_path'))
        self.assertEqual(len(owner.recovery_failure_stages), 8)
        self.assertIsNone(owner.record_recovery_failure(999, 'first_path'))
        self.assertNotIn(999, owner.recovery_failure_stages)


    def test_new_snapshot_failure_never_reuses_a_prior_parent_recovery_stage(self):
        value, owner = self.real_self_group_failure()
        with patch.object(owner.library, 'proc_pidinfo', return_value=0):
            self.assertIsNone(owner.recover_snapshot(123))
        self.assertEqual(owner.recovery_failure_stages[123], 'first_kernel')
        errors = list(owner.errors)
        with patch.object(owner.library, 'proc_pidpath', return_value=0), \
                patch.object(acceptance.os, 'kill', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'Live owned process identity unavailable') as failure:
                owner.snapshot(123)
        owner.reject(123, str(failure.exception))
        row = owner.failure_observations[-1]
        self.assertEqual(row['kind'], 'live_identity_unavailable')
        self.assertNotIn('recoveryFailureStage', row)
        self.assertTrue(all(error in owner.errors for error in errors))
        value['cleanup']['ownershipErrors'] = owner.errors
        value['ownershipFailureObservations'] = [row]
        rows, _ = self.emitted_group_rows(value)
        self.assertEqual(rows, [[row]])


class OwnershipProofEmitterContracts(unittest.TestCase):
    def producer(self, mode):
        spec = importlib.util.spec_from_file_location(
            'producer_contracts', Path(__file__).with_name('test-hosted-native-owner-tests.py'))
        model = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(model)
        kernel = model.Kernel()
        original = kernel.proc_pidinfo
        calls = 0

        def record(pid, flavor, argument, pointer, size):
            nonlocal calls
            result = original(pid, flavor, argument, pointer, size)
            pointer._obj.status = 5 if pid == 345 else 2
            if mode == 'unsealed' and pid == 345 and argument == 0:
                return 0
            if mode == 'saturated' and pid == 123:
                calls += 1
                if calls <= 2:
                    return 0
            return result

        with patch.object(model.runner.watchdog.ctypes, 'CDLL', return_value=kernel), \
                patch.object(model.runner.os, 'kill', side_effect=kernel.kill):
            owner = model.runner.BoundedOwnership(123, 501)
            if mode == 'unsealed':
                kernel.processes[234] = (234, 101, 8, '/fixture/private-parent', 234, 123, 501, 501)
                with patch.object(kernel, 'proc_pidinfo', side_effect=record):
                    owner.refresh()
                self.assertIn(234, owner.known)
                kernel.processes[345] = (345, 102, 9, '/fixture/private-child', 234, 234, 501, 501)
            else:
                owner.recovery_failure_stages = {pid: 'first_kernel' for pid in range(400, 408)}
            with patch.object(kernel, 'proc_pidinfo', side_effect=record):
                owner.refresh()
        self.assertEqual(owner.errors, ['Live owned process identity unavailable'])
        self.assertEqual(kernel.signals, [])
        return owner.failure_observations[0]

    def emit(self, candidates):
        value = AcceptanceContracts().failed_runner()
        value['cleanup']['ownershipErrors'] = ['Live owned process identity unavailable']
        value['ownershipFailureObservations'] = candidates
        output = io.StringIO()
        with redirect_stdout(output):
            acceptance.native_failure_diagnostics(value, Path('/synthetic/missing-log'))
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_actual_unsealed_parent_group_and_saturated_recovery_witnesses_reach_real_emitter(self):
        for mode in ['unsealed', 'saturated']:
            with self.subTest(mode=mode):
                row = self.producer(mode)
                output = self.emit([row])
                self.assertEqual(output[-1], {'nativeOwnershipFailureObservations': [row]})
                self.assertNotIn('private', json.dumps(output))
                self.assertNotIn('pid', row)
                self.assertEqual(row['recoveryProofStage'],
                                 'retained_identity' if mode == 'unsealed' else 'first_kernel')
                if mode == 'unsealed':
                    self.assertEqual(row['terminalRefusalReason'], 'parent_admission')
                    self.assertTrue(row['terminalParentGroupMatchesSeal'])
                    self.assertTrue(row['terminalParentGroupIsSelf'])
                    self.assertFalse(row['terminalParentGroupMatchesLeader'])
                else:
                    self.assertNotIn('recoveryFailureStage', row)

    def test_new_witness_shapes_reject_partial_unknown_and_nonboolean_fields(self):
        row = self.producer('unsealed')
        terminal = [key for key in row if key.startswith('terminal')]
        invalid = [
            {**row, 'recoveryProofStage': '/fixture/private'},
            {**row, 'recoveryProofStage': None},
            {**row, 'terminalRefusalReason': 'unreviewed'},
            {**row, 'terminalChildRole': '/fixture/private'},
            {**row, 'terminalParentIdentityKnown': 1},
            {**row, 'pid': 123},
        ]
        for key in terminal:
            invalid.append({name: value for name, value in row.items() if name != key})
            if key not in ['terminalRefusalReason', 'terminalChildRole']:
                invalid.append({**row, key: 1})
        for changed in invalid:
            with self.subTest(fields=sorted(changed)):
                self.assertEqual(self.emit([changed, row])[-1],
                                 {'nativeOwnershipFailureObservations': [row]})
        self.assertEqual(self.emit([row] * 12)[-1],
                         {'nativeOwnershipFailureObservations': [row] * 8})


if __name__ == '__main__':
    unittest.main()
