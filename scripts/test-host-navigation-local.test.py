import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('local_navigation', Path(__file__).with_name('test-host-navigation-local.py'))
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)


class SyntheticOutput(io.StringIO):
    def __init__(self):
        super().__init__()
        self.buffer = io.BytesIO()


class NavigationCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source.swift'
        self.source.write_text('\n'.join('@Test func synthetic' + str(index) + '() {}' for index in range(6)) + '\n')
        self.source.chmod(0o600)
        self.cleanup = {'reaped': True, 'remainingOwnedProcesses': 0,
                        'unverifiedOwnedProcesses': 0, 'pendingOwnedChildren': 0,
                        'naturalSurvivorCount': 0, 'ownershipErrors': []}
        self.driver = Mock()
        self.driver.validate.return_value = Path('/synthetic/toolchain/usr/bin/swift-test')
        self.fixture = None
        self.command = None
        self.environment = None

    def execute(self, *, cleanup=None, code=0, output=None, error=None, mutate=False):
        def owned(command, root, environment, log):
            self.fixture = log.parent
            self.command = command
            self.environment = environment
            if error is not None:
                raise error
            navigation.isolation.write_private(
                log, output if output is not None else b'Test run with 6 tests in 1 suite passed.\n')
            if mutate:
                self.source.write_text('@Test func changed() {}\n')
            return {'exitCode': code, 'cleanup': self.cleanup if cleanup is None else cleanup}
        with patch.object(navigation, 'ROOT', self.root), \
                patch.object(navigation, 'SOURCES', {'source.swift': 'Tests/HostNavigationTests/Synthetic.swift'}), \
                patch.object(navigation.sys, 'platform', 'darwin'), \
                patch.object(navigation.sys, 'argv', ['test-host-navigation-local.py']), \
                patch.object(navigation.sys, 'stdout', SyntheticOutput()), \
                patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(self.root),
                                       'DEVELOPER_DIR': '/synthetic/toolchain',
                                       'PATH': '/usr/bin:/bin'}, clear=True), \
                patch.object(navigation.drivers, 'SelectedSwiftDriver', return_value=self.driver), \
                patch.object(navigation.isolation, 'run_owned', side_effect=owned) as run:
            result = navigation.run()
        return result, run

    def test_verified_natural_completion_removes_only_its_synthetic_fixture(self):
        result, run = self.execute()
        self.assertEqual(result, 0)
        self.assertEqual(run.call_count, 1)
        self.assertFalse(self.fixture.exists())
        self.assertTrue(self.source.exists())
        self.assertEqual(self.driver.validate.call_count, 2)
        receipt = json.loads((self.root / 'local/host-navigation-contracts/receipt.json').read_bytes())
        self.assertTrue(receipt['navigationTestsExecuted'])
        self.assertFalse(receipt['applicationExecution'])
        self.assertTrue(receipt['ownership']['selectedDriverValidated'])

    def test_each_unverified_cleanup_dimension_retains_the_failed_fixture(self):
        cases = [{'reaped': False}, {'remainingOwnedProcesses': 1},
                 {'unverifiedOwnedProcesses': 1}, {'pendingOwnedChildren': 1},
                 {'naturalSurvivorCount': 1}, {'ownershipErrors': ['Synthetic rejection']}]
        for changed in cases:
            with self.subTest(changed=changed):
                result, _ = self.execute(cleanup={**self.cleanup, **changed})
                self.assertEqual(result, 1)
                self.assertTrue(self.fixture.exists())

    def test_timeout_nonzero_and_zero_tests_never_qualify_or_delete_the_fixture(self):
        cases = [(124, b'Test run with 6 tests in 1 suite passed.\n'),
                 (1, b'Test run with 6 tests in 1 suite passed.\n'),
                 (-9, b'Build complete.\n'), (0, b'Test run with 0 tests passed.\n')]
        for code, output in cases:
            with self.subTest(code=code, output=output):
                result, _ = self.execute(code=code, output=output)
                self.assertNotEqual(result, 0)
                self.assertTrue(self.fixture.exists())

    def test_post_join_driver_change_retains_the_receipt_and_fixture(self):
        self.driver.validate.side_effect = [Path('/synthetic/toolchain/usr/bin/swift-test'),
                                            ValueError('Synthetic driver changed')]
        result, _ = self.execute()
        self.assertEqual(result, 1)
        self.assertTrue(self.fixture.exists())
        receipt = json.loads((self.root / 'local/host-navigation-contracts/receipt.json').read_bytes())
        self.assertFalse(receipt['ownership']['selectedDriverValidated'])
        self.assertEqual(receipt['ownership']['selectedDriverFailure'], 'ValueError')

    def test_source_change_after_owned_join_cannot_qualify(self):
        result, _ = self.execute(mutate=True)
        self.assertEqual(result, 1)
        self.assertTrue(self.fixture.exists())

    def test_owned_runner_interrupt_and_error_retain_the_fixture(self):
        for error in [KeyboardInterrupt(), OSError('Synthetic runner failed')]:
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(type(error)):
                    self.execute(error=error)
                self.assertTrue(self.fixture.exists())

    def test_exact_selected_alias_arguments_and_closed_environment_are_preserved(self):
        result, _ = self.execute()
        self.assertEqual(result, 0)
        self.assertEqual(self.command[0], '/synthetic/toolchain/usr/bin/swift-test')
        self.assertEqual(self.command[1], '--package-path')
        self.assertNotIn('test', self.command)
        self.assertEqual(self.command[self.command.index('--filter') + 1], 'HostOptionalNavigationTests')
        self.assertEqual(self.command[self.command.index('--jobs') + 1], '1')
        self.assertEqual(self.command[self.command.index('--build-system') + 1], 'swiftbuild')
        self.assertIn('--no-parallel', self.command)
        self.assertIn('-warnings-as-errors', self.command)
        self.assertEqual(self.environment['HOME'], str(self.fixture))
        self.assertEqual(self.environment['CFFIXED_USER_HOME'], str(self.fixture))
        for key in ['TMPDIR', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME',
                    'EDITH_EXTENSION_DATA_ROOT', 'EDITH_EXTENSION_STATE_ROOT']:
            self.assertTrue(Path(self.environment[key]).is_relative_to(self.fixture))


if __name__ == '__main__':
    unittest.main()
