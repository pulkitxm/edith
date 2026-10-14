import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('keep_local', Path(__file__).with_name('test-keep-awake-local.py'))
model = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model)


class KeepAwakeLocalContracts(unittest.TestCase):
    def setUp(self):
        temporary = Path(os.environ['TMPDIR'])
        self.directory = tempfile.TemporaryDirectory(dir=temporary)
        self.root = Path(self.directory.name).resolve()
        self.methods = {model.HOSTED_METHOD, *(f'originalMethod{i}' for i in range(46))}
        self.output = '\n'.join([*(f'Test {name}() passed after 0.001 seconds.'
                                  for name in sorted(self.methods - {model.HOSTED_METHOD})),
                                 f'Test {model.HOSTED_METHOD}() skipped: disabled.',
                                 'Test run with 47 tests in 9 suites passed.']).encode()

    def tearDown(self):
        self.directory.cleanup()

    def test_exact_original_method_inventory_and_hosted_skip_are_required(self):
        methods = model.test_methods(model.ROOT)
        self.assertEqual(len(methods), 47)
        self.assertIn(model.HOSTED_METHOD, methods)
        self.assertEqual(model.result(self.output, self.methods),
                         {'executedMethods': 46, 'skippedMethods': [model.HOSTED_METHOD], 'passed': True})

    def test_missing_duplicate_summary_unknown_method_and_executed_hosted_control_reject(self):
        alternatives = [self.output.replace(b'Test originalMethod0() passed', b'Test unknown() passed'),
                        self.output.replace(b'Test originalMethod0() passed', b'Test originalMethod1() passed'),
                        self.output.replace(b'skipped: disabled.', b'passed after 0.1 seconds.'),
                        self.output + b'\nTest run with 47 tests passed.',
                        self.output.replace(b'47 tests', b'0 tests')]
        for output in alternatives:
            with self.subTest(output=output[-80:]):
                self.assertFalse(model.result(output, self.methods)['passed'])

    def test_private_environment_never_inherits_hosted_or_credential_authority(self):
        fixture = model.isolation.private_directory(self.root / 'fixture')
        modules = model.isolation.private_directory(self.root / 'modules')
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_TOKEN': 'synthetic-token',
                                     'EDITH_KEEP_AWAKE_HOSTED_ACCEPTANCE': '1',
                                     'HOME': '/synthetic/foreign', 'TMPDIR': '/synthetic/foreign'}, clear=True):
            values = model.environment(fixture, modules)
        for key in ['GITHUB_ACTIONS', 'GITHUB_TOKEN', 'EDITH_KEEP_AWAKE_HOSTED_ACCEPTANCE',
                    'EDITH_FUNCTIONAL_FIXTURE']:
            self.assertNotIn(key, values)
        for key in ['HOME', 'CFFIXED_USER_HOME', 'TMPDIR', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME',
                    'EDITH_EXTENSION_DATA_ROOT', 'EDITH_EXTENSION_STATE_ROOT', 'XDG_RUNTIME_DIR']:
            self.assertTrue(Path(values[key]).is_relative_to(fixture))
        self.assertFalse(values['EDITH_APPLICATION_IDENTIFIER'].startswith('com.pulkit.edith.tests.'))
        self.assertFalse(values['EDITH_SHARED_DEFAULTS_SUITE'].startswith('com.pulkit.edith.tests.'))
        self.assertEqual(values['EXTENSION_SWIFT_JOBS'], '1')

    def test_command_uses_actual_package_one_job_and_owned_scratch_paths(self):
        class Driver:
            def validate(self):
                return Path('/synthetic/toolchain/swift-test')
        with patch.dict(os.environ, {'DEVELOPER_DIR': '/synthetic/developer'}):
            values = model.command(Driver(), self.root / 'fixture', self.root / 'storage')
        self.assertEqual(values[0], '/synthetic/toolchain/swift-test')
        self.assertNotIn('test', values)
        self.assertEqual(values[values.index('--package-path') + 1], str(model.ROOT / 'Extensions/keepAwake'))
        self.assertEqual(values[values.index('--jobs') + 1], '1')
        self.assertEqual(values[values.index('--scratch-path') + 1], str(self.root / 'storage/build'))
        self.assertNotIn('--filter', values)

    def test_fixture_support_uses_explicit_private_temporary_root(self):
        source = (model.ROOT / 'Extensions/fixtureSupport/Tests/Support/EngineFixture.swift').read_text()
        self.assertNotIn('FileManager.default.temporaryDirectory', source)
        self.assertIn('ProcessInfo.processInfo.environment["TMPDIR"]', source)
        self.assertIn('.standardizedFileURL.resolvingSymlinksInPath()', source)
        self.assertLess(source.index('.standardizedFileURL.resolvingSymlinksInPath()'),
                        source.index('attributesOfItem(atPath: temporary.path)'))
        self.assertNotIn('temporaryPath == temporary.path', source)
        self.assertIn('temporary.resolvingSymlinksInPath().path', source)
        self.assertIn('attributes[.ownerAccountID] as? UInt32 == getuid()', source)
        self.assertIn('attributes[.posixPermissions] as? Int == 0o700', source)

    def test_make_route_has_shared_swift_budget_and_no_hosted_environment_substitution(self):
        make = (model.ROOT / 'Makefile').read_text()
        route = make.split('ci-extension-keep-awake-local:\n', 1)[1].split('\n\n', 1)[0]
        self.assertEqual(route, '\tpython3 -I -B scripts/test-keep-awake-local.test.py\n'
                               '\tpython3 -I -B scripts/test-keep-awake-local.py')
        gate = (model.ROOT / 'scripts/make-resource-gate.py').read_text()
        self.assertIn('"ci-extension-keep-awake-local": "swift-test"', gate)
        self.assertNotIn('GITHUB', route)

    def test_inventory_prunes_compiler_cache_and_tracks_physical_lock_edits(self):
        names = ['Extensions/keepAwake/Main.swift', 'Extensions/keepAwake/Package.resolved',
                 'Extensions/fixtureSupport/Main.swift', 'Packages/ExtensionSupport/Main.swift',
                 'scripts/test-keep-awake-local.py', 'scripts/test-account-sdk-local.py',
                 'scripts/run-host-swift-testing.py', 'scripts/hosted-native-owner-tests.py',
                 'scripts/hosted-host-tests/watchdog.py', 'Extensions/keepAwake/.build/ignored.swift']
        for relative in names:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic source')
        with patch.object(model.subprocess, 'check_output', return_value=b'Extensions/keepAwake/Package.resolved\0'):
            before = model.source_inventory(self.root)
            (self.root / 'Extensions/keepAwake/Package.resolved').write_text('changed physical lock')
            after = model.source_inventory(self.root)
        self.assertNotIn('Extensions/keepAwake/.build/ignored.swift', before)
        self.assertNotEqual(before['Extensions/keepAwake/Package.resolved'],
                            after['Extensions/keepAwake/Package.resolved'])
        (self.root / 'Extensions/keepAwake/linked').symlink_to(self.root / 'Packages/ExtensionSupport', target_is_directory=True)
        with patch.object(model.subprocess, 'check_output', return_value=b''):
            with self.assertRaises(ValueError):
                model.source_inventory(self.root)

    def run_mocked(self, cleanup, mutate_source=False, driver_failure=False):
        fixture_paths = []
        validations = []
        class Driver:
            def __init__(self, developer, entry):
                self.entry = entry
            def validate(self):
                validations.append(self.entry)
                if driver_failure and len(validations) == 2:
                    raise ValueError('Synthetic immutable driver change')
                return Path('/synthetic/toolchain/swift-test')
        def run_owned(command, root, environment, output, deadline, cadence):
            self.assertEqual((deadline, cadence), (900, 0.5))
            self.assertNotIn('GITHUB_ACTIONS', environment)
            fixture_paths.append(output.parent)
            output.write_bytes(self.output)
            return {'exitCode': 0, 'failure': None, 'timedOut': False,
                    'logBoundExceeded': False, 'cleanup': cleanup}
        inventories = [{'actual-source': 'synthetic-hash'}, {'actual-source': 'changed' if mutate_source else 'synthetic-hash'}]
        with patch.object(model, 'ROOT', self.root), patch.object(model.sys, 'argv', ['test-keep-awake-local.py']), \
                patch.object(model.sys, 'platform', 'darwin'), \
                patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(self.root), 'DEVELOPER_DIR': '/synthetic/developer'}), \
                patch.object(model.drivers, 'SelectedSwiftDriver', Driver), \
                patch.object(model.isolation, 'run_owned', side_effect=run_owned), \
                patch.object(model, 'source_inventory', side_effect=inventories), \
                patch.object(model, 'test_methods', return_value=self.methods), \
                patch('builtins.print'):
            if driver_failure:
                with self.assertRaises(ValueError):
                    model.main()
                status = 1
            else:
                status = model.main()
        receipt = json.loads((self.root / 'local/keep-awake-contracts/last-receipt.json').read_text())
        return status, receipt, fixture_paths, validations

    def test_success_requires_natural_cleanup_and_driver_validation_before_fixture_removal(self):
        cleanup = {'reaped': True, 'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0,
                   'ownershipErrors': [], 'pendingOwnedChildren': 0, 'naturalSurvivorCount': 0}
        status, receipt, paths, validations = self.run_mocked(cleanup)
        self.assertEqual(status, 0)
        self.assertTrue(receipt['passed'])
        self.assertFalse(receipt['hostedControlQualified'])
        self.assertEqual(validations, ['swift-test', 'swift-test'])
        self.assertFalse(paths[0].exists())

    def test_every_unsafe_cleanup_source_or_driver_mutation_retains_fixture_and_cannot_pass(self):
        base = {'reaped': True, 'remainingOwnedProcesses': 0, 'unverifiedOwnedProcesses': 0,
                'ownershipErrors': [], 'pendingOwnedChildren': 0, 'naturalSurvivorCount': 0}
        for name, value in [('reaped', False), ('remainingOwnedProcesses', 1),
                            ('unverifiedOwnedProcesses', 1), ('ownershipErrors', ['Synthetic refusal']),
                            ('pendingOwnedChildren', 1), ('naturalSurvivorCount', 1),
                            ('source', True), ('driver', True)]:
            with self.subTest(name=name):
                cleanup = dict(base)
                if name in cleanup:
                    cleanup[name] = value
                status, receipt, paths, validations = self.run_mocked(
                    cleanup, mutate_source=name == 'source', driver_failure=name == 'driver')
                self.assertEqual(status, 1)
                self.assertFalse(receipt['passed'])
                self.assertTrue(paths[0].exists())
                self.assertEqual(validations, ['swift-test', 'swift-test'])


class KeepPackageCarrierContracts(unittest.TestCase):
    def test_original_argv_uses_the_shared_carrier_and_cannot_mint_authority_from_a_plain_driver(self):
        class Driver:
            def validate(self):
                return Path('/synthetic/toolchain/swift-test')
        self.assertIs(model.drivers, model.isolation.DRIVERS)
        self.assertIs(model.drivers, model.isolation.OWNERSHIP.DRIVERS)
        driver = Driver()
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary).resolve()
            with patch.dict(os.environ, {'DEVELOPER_DIR': '/synthetic/developer'}):
                arguments = model.command(driver, root / 'fixture', root / 'storage')
            self.assertIs(type(arguments), model.isolation.DRIVERS.SelectedPackageArguments)
            self.assertIs(arguments.driver, driver)
            self.assertEqual(arguments[0], str(driver.validate()))
            self.assertEqual(arguments[arguments.index('--package-path') + 1],
                             str(model.ROOT / 'Extensions/keepAwake'))
            self.assertNotIn('--filter', arguments)
            output = root / 'unadmitted.log'
            with patch.object(model.isolation.subprocess, 'Popen') as process:
                with self.assertRaisesRegex(ValueError, 'Authenticated selected package invocation required'):
                    model.isolation.run_owned(arguments, model.ROOT, {}, output)
            process.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
