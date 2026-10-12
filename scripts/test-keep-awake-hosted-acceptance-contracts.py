from pathlib import Path
from contextlib import redirect_stdout
import importlib.util
import io
import json
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'keep_awake_acceptance', Path(__file__).with_name('test-keep-awake-hosted-acceptance.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceContracts(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
