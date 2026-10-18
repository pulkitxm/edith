import ast
import importlib.util
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('owner_local', Path(__file__).with_name('test-host-core-owner-local.py'))
owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owner)


class OwnerLocalTests(unittest.TestCase):
    def setUp(self):
        self.storage = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.storage.cleanup)
        self.root = Path(self.storage.name).resolve()

    def test_public_cli_has_fixed_unit_filter_and_original_native_flags(self):
        class Driver:
            developer = Path('/synthetic/developer')

            def validate(self):
                return Path('/synthetic/swift-test')
        command = owner.arguments(Driver(), self.root, self.root / 'package')
        self.assertEqual(command[0:2], ['/synthetic/swift-test', '--package-path'])
        self.assertNotIn('test', command)
        self.assertEqual(command[-2:], ['--filter', 'HostCoreOwner'])
        self.assertEqual(command[command.index('--jobs') + 1], '1')
        self.assertEqual(command[command.index('--build-system') + 1], 'native')
        self.assertIn('--no-parallel', command)
        self.assertIn('-j1', command)
        self.assertIn('-plugin-path', command)
        self.assertNotIn('--skip-build', command)
        for name in ['cache', 'config', 'security']:
            self.assertIn(str(self.root / name), command)

    def test_child_environment_has_only_private_storage_and_no_ambient_authority(self):
        with patch.dict(os.environ, {
            'PATH': '/usr/bin:/bin', 'DEVELOPER_DIR': '/synthetic/developer',
            'GH_TOKEN': 'synthetic-secret', 'GITHUB_ACTIONS': 'true',
            'PYTHONPATH': '/synthetic/preload', 'DYLD_LIBRARY_PATH': '/synthetic/library',
            'HOME': '/synthetic/foreign-home', 'EDITH_SHARED_DEFAULTS_SUITE': 'foreign',
        }, clear=True):
            value = owner.environment(self.root, self.root / 'modules')
        for key in ['GH_TOKEN', 'GITHUB_ACTIONS', 'PYTHONPATH', 'DYLD_LIBRARY_PATH']:
            self.assertNotIn(key, value)
        self.assertEqual(value['HOME'], str(self.root))
        self.assertEqual(value['CFFIXED_USER_HOME'], str(self.root))
        self.assertEqual(value['TMPDIR'], str(self.root / 'tmp') + '/')
        self.assertEqual(value['PYTHONDONTWRITEBYTECODE'], '1')
        self.assertEqual(value['EDITH_TEST_NATIVE_CAPTURE'], '0')
        self.assertTrue(value['EDITH_APPLICATION_IDENTIFIER'].startswith('com.pulkit.edith.dev.'))
        for key in ['XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME',
                    'EDITH_EXTENSION_DATA_ROOT', 'EDITH_EXTENSION_STATE_ROOT']:
            self.assertTrue(Path(value[key]).is_relative_to(self.root))

    def test_exact_completion_rejects_zero_missing_extra_and_wrong_parameter_rows(self):
        source = (owner.ROOT / owner.SOURCE).read_text()
        methods = re.findall(r'@Test(?:\([^\n]*\))?\s*(?:@MainActor\s+)?func\s+(\w+)', source)
        self.assertEqual(len(methods), 13)
        text = '\n'.join([*(f'◇ Test {name}() started.' for name in methods),
                          *(f'✔ Test {name}() passed after 0.001 seconds.' for name in methods),
                          *(f'✔ Suite {name} passed after 0.001 seconds.' for name in owner.SUITES),
                          *(f'argument iteration → {index} to liveChildWithoutProtocolRequestsRetiresAndJoins'
                            for index in range(8)), 'Test run with 13 tests in 3 suites passed'])
        self.assertTrue(owner.completion(text, methods))
        for changed in ['', text.replace('13 tests', '0 tests'), text.replace('iteration → 7', 'iteration → 8'),
                        text.replace(f'✔ Test {methods[0]}()', '✔ Test foreign()'),
                        text + '\n✔ Suite Foreign passed after 0.001 seconds.']:
            self.assertFalse(owner.completion(changed, methods))

    def test_make_route_has_swift_budget_and_never_uses_app_fixture_runner(self):
        root = owner.ROOT
        make = (root / 'Makefile').read_text()
        target = make.split('ci-host-core-owner-local:\n')[1].split('\n\n')[0]
        self.assertEqual(target.splitlines(), [
            '\tpython3 -I -B scripts/test-host-core-owner-local.test.py',
            '\tpython3 -I -B scripts/test-host-core-owner-local.py'])
        gate = ast.parse((root / 'scripts/make-resource-gate.py').read_text())
        budgets = next(node.value for node in gate.body if isinstance(node, ast.Assign)
                       and any(isinstance(name, ast.Name) and name.id == 'EXACT' for name in node.targets))
        self.assertEqual(ast.literal_eval(budgets)['ci-host-core-owner-local'], 'swift-test')
        producer = (root / 'scripts/test-host-core-owner-local.py').read_text()
        self.assertIn('return native.run_selected_original(command, ROOT, child_environment, output)', producer)
        self.assertIn('result[\'passed\'] = result[\'passed\'] and exact', producer)
        self.assertIn('if qualified:\n                shutil.rmtree(fixture)', producer)
        self.assertNotIn('test-host-core.mjs', producer)
        self.assertNotIn('build.sh', producer)

    def test_owned_runner_parent_home_is_private_and_restored_on_success_and_failure(self):
        for throws in [False, True]:
            def native(command, root, environment, output):
                self.assertEqual(Path.home(), self.root)
                self.assertEqual(dict(os.environ), {'HOME': str(self.root)})
                if throws:
                    raise RuntimeError('Synthetic owner failure')
                return {'passed': False}
            with patch.dict(os.environ, {'HOME': '/synthetic/foreign-home', 'GH_TOKEN': 'synthetic'}, clear=True), \
                    patch.object(owner.native, 'run_selected_original', side_effect=native):
                if throws:
                    with self.assertRaisesRegex(RuntimeError, 'Synthetic owner failure'):
                        owner.execute([], {'HOME': str(self.root)}, self.root)
                else:
                    self.assertEqual(owner.execute([], {'HOME': str(self.root)}, self.root), {'passed': False})
                self.assertEqual(dict(os.environ), {'HOME': '/synthetic/foreign-home', 'GH_TOKEN': 'synthetic'})

    def test_selected_runner_uses_the_existing_shared_namespace(self):
        self.assertIs(owner.native, owner.isolation.OWNERSHIP)
        self.assertIs(owner.driver_api, owner.native.DRIVERS)
        self.assertTrue(callable(owner.native.run_selected_original))

    def test_invalid_source_selection_never_starts_native_process(self):
        package = self.root / 'Packages/EdithHost'
        for name in [owner.SOURCE, owner.PROGRAM, 'Packages/EdithHost/Package.swift']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic source')
        with patch.object(owner, 'ROOT', self.root), patch.object(owner.sys, 'platform', 'darwin'), \
                patch.object(owner.sys, 'argv', ['runner']), \
                patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(self.root)}, clear=True), \
                patch.object(owner.native, 'run_selected_original') as native:
            with self.assertRaisesRegex(ValueError, 'source selection changed'):
                owner.run()
            native.assert_not_called()
        self.assertFalse(any((self.root / 'local/host-core-owner').glob('fixture-*')))


if __name__ == '__main__':
    unittest.main()
