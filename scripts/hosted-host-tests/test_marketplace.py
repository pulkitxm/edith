import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('marketplace', Path(__file__).with_name('marketplace.py'))
marketplace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(marketplace)


class MarketplaceDiagnosticsTests(unittest.TestCase):
    def test_batch_exception_retains_failure_receipt_without_claiming_execution_or_exit(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                with patch.object(sys, 'argv', ['marketplace.py']), patch.object(
                        marketplace.subprocess, 'check_output', side_effect=[
                            'a' * 40, '/Applications/Xcode.app/Contents/Developer']), patch.object(
                        marketplace.watchdog, 'admit'), patch.object(
                        marketplace.watchdog, 'canonical_path', side_effect=lambda path, **_: Path(path)), patch.object(
                        marketplace.watchdog, 'run_batch', side_effect=RuntimeError('synthetic failure')):
                    with self.assertRaises(RuntimeError):
                        marketplace.main()
                receipt = json.loads(Path('local/hosted-marketplace-tests/result.json').read_text())
                self.assertEqual(receipt, {'schema': 1, 'sourceCommit': 'a' * 40, 'passed': False})
            finally:
                os.chdir(original)

    def test_command_preserves_the_full_native_suite_without_filters_or_serial_override(self):
        developer = '/Applications/Xcode_26.6.app/Contents/Developer'
        self.assertEqual(marketplace.command(developer), [
            developer + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift', 'test',
            '--package-path', 'Packages/ExtensionMarketplace', '--build-system', 'native',
            '--jobs', '1'])

    def test_only_actual_marketplace_testing_names_are_admitted_for_sampling(self):
        for name in ['swiftpm-testing', 'swiftpm-testing-helper', 'ExtensionMarketplacePackageTests']:
            self.assertTrue(marketplace.is_testing_process('/owned/' + name))
        for name in ['EdithHostPackageTests', 'Edith', 'bash', 'other-swiftpm-testing-helper']:
            self.assertFalse(marketplace.is_testing_process('/owned/' + name))

    def test_timeout_failure_missing_execution_or_survivors_cannot_be_success(self):
        result = {'exitCode': 0, 'testsCompleted': True, 'observedTestingProcess': True,
                  'timedOut': False, 'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0}
        self.assertTrue(marketplace.passed(result))
        for key, value in [('exitCode', 1), ('testsCompleted', False),
                           ('observedTestingProcess', False), ('timedOut', True),
                           ('remainingOwnedProcesses', 1), ('unverifiedOwnedProcesses', 1)]:
            with self.subTest(key=key):
                self.assertFalse(marketplace.passed({**result, key: value}))

    def test_real_batch_receipt_uses_injected_marketplace_process_classifier(self):
        class Child:
            pid = 123
            returncode = 0

            def poll(self):
                return 0

            def wait(self, timeout):
                return 0

        class Ownership:
            def __init__(self, leader, uid):
                self.known = {123: (123, 1, 2, '/owned/ExtensionMarketplacePackageTests', 123)}

            def refresh(self):
                return []

        def create(arguments, stdout, **options):
            stdout.write(b'Test run with 59 tests in 6 suites passed\n')
            return Child()

        with tempfile.TemporaryDirectory() as directory, patch.object(
                marketplace.watchdog, 'owned_crash_reports', return_value=[]):
            result = marketplace.watchdog.run_batch(
                'marketplace', ['synthetic'], Path(directory), 900,
                process_factory=create, ownership_factory=Ownership,
                testing_process=marketplace.is_testing_process)
        self.assertTrue(marketplace.passed(result))
        self.assertEqual(result['knownOwnedProcesses'][0]['pid'], 123)


if __name__ == '__main__':
    unittest.main()
