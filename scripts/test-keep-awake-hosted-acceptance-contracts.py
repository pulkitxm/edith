from pathlib import Path
import importlib.util
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'keep_awake_acceptance', Path(__file__).with_name('test-keep-awake-hosted-acceptance.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceContracts(unittest.TestCase):
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
