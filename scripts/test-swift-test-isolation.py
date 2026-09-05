import json
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = REPO / 'Packages' / 'Edith' / 'test.sh'
KEYS = ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME',
        'EDITH_AGENT_MACH_SERVICE', 'EDITH_SHARED_DEFAULTS_SUITE',
        'EDITH_HELPER_DEFAULTS_SUITE', 'EDITH_TEST_RUNTIME_ROOT', 'EDITH_DATABASE_KEYCHAIN_SERVICE']


class SwiftTestIsolationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='edith-wrapper-check-')
        self.root = pathlib.Path(self.directory.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'defaults-calls'
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in KEYS and key != 'EDITH_SHARED_DEFAULTS_SUITE'}
        self.environment.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                                WRAPPER_DEFAULTS_CALLS=str(self.calls))
        self.tool('swift', """#!/usr/bin/env python3
import json, os, sys
keys = ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME', 'EDITH_AGENT_MACH_SERVICE', 'EDITH_SHARED_DEFAULTS_SUITE', 'EDITH_HELPER_DEFAULTS_SUITE', 'EDITH_TEST_RUNTIME_ROOT', 'EDITH_DATABASE_KEYCHAIN_SERVICE']
print(json.dumps({key: os.environ.get(key) for key in keys}))
sys.exit(int(os.environ.get('WRAPPER_SWIFT_EXIT', '0')))
""")
        self.tool('xcode-select', '#!/bin/sh\nprintf "/missing-test-developer\\n"\n')
        self.tool('defaults', """#!/usr/bin/env python3
import json, os, pathlib, sys
with pathlib.Path(os.environ['WRAPPER_DEFAULTS_CALLS']).open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
""")

    def tearDown(self):
        self.directory.cleanup()

    def tool(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o700)

    def run_wrapper(self, **environment):
        return subprocess.run([str(WRAPPER), '--filter', 'IsolationProbe'],
                              cwd=REPO, env=dict(self.environment, **environment),
                              text=True, capture_output=True, timeout=10)

    def defaults_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_defaults_are_private_and_only_owned_state_is_cleaned(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        values = json.loads(result.stdout)
        runtime = pathlib.Path(values['EDITH_TEST_RUNTIME_ROOT'])
        for name in ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME']:
            self.assertTrue(pathlib.Path(values[name]).is_relative_to(runtime))
        self.assertTrue(values['EDITH_AGENT_MACH_SERVICE'].startswith('com.pulkit.edith.tests.'))
        self.assertNotEqual(values['EDITH_AGENT_MACH_SERVICE'], 'com.pulkit.edith.agent')
        self.assertTrue(values['EDITH_DATABASE_KEYCHAIN_SERVICE'].startswith('com.pulkit.edith.tests.'))
        self.assertFalse(runtime.exists())
        self.assertEqual(self.defaults_calls(), [
            ['delete', values['EDITH_SHARED_DEFAULTS_SUITE']],
            ['delete', values['EDITH_HELPER_DEFAULTS_SUITE']]])

    def test_inherited_isolated_paths_and_domains_are_preserved(self):
        supplied = {}
        for name in ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME']:
            path = self.root / name.lower()
            path.mkdir()
            (path / 'preserved').write_text(name)
            supplied[name] = str(path)
        supplied.update(EDITH_SHARED_DEFAULTS_SUITE='com.pulkit.edith.tests.inherited.shared',
                        EDITH_HELPER_DEFAULTS_SUITE='com.pulkit.edith.tests.inherited.helper',
                        EDITH_AGENT_MACH_SERVICE='com.pulkit.edith.test.inherited.agent')
        result = self.run_wrapper(**supplied)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = json.loads(result.stdout)
        for name, value in supplied.items():
            self.assertEqual(values[name], value)
        for name in ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME']:
            self.assertEqual((pathlib.Path(values[name]) / 'preserved').read_text(), name)
        self.assertEqual(self.defaults_calls(), [])

    def test_keychain_service_is_fresh_even_with_inherited_production_value(self):
        result = self.run_wrapper(EDITH_DATABASE_KEYCHAIN_SERVICE='com.pulkit.edith.database.credentials')
        self.assertEqual(result.returncode, 0, result.stderr)
        values = json.loads(result.stdout)
        self.assertTrue(values['EDITH_DATABASE_KEYCHAIN_SERVICE'].startswith('com.pulkit.edith.tests.'))

    def test_production_domains_are_rejected_before_any_cleanup(self):
        for name, value in [('EDITH_SHARED_DEFAULTS_SUITE', 'com.pulkit.edith.shared'),
                            ('EDITH_HELPER_DEFAULTS_SUITE', 'com.pulkit.edith.helper'),
                            ('EDITH_AGENT_MACH_SERVICE', 'com.pulkit.edith.agent')]:
            with self.subTest(name=name):
                result = self.run_wrapper(**{name: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Test isolation refused', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(self.defaults_calls(), [])

    def test_production_paths_and_symlink_escapes_are_rejected(self):
        outside = pathlib.Path.home() / 'Library' / 'Application Support' / 'Edith'
        link = self.root / 'escape'
        link.symlink_to(outside)
        for name in ['EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME']:
            for value in [str(outside), str(link), '/tmp', '../relative']:
                with self.subTest(name=name, value=value):
                    result = self.run_wrapper(**{name: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Test isolation refused', result.stderr)
                    self.assertEqual(self.defaults_calls(), [])

    def test_failure_preserves_owned_artifacts_and_defaults(self):
        result = self.run_wrapper(WRAPPER_SWIFT_EXIT='7')
        self.assertEqual(result.returncode, 7)
        values = json.loads(result.stdout)
        runtime = pathlib.Path(values['EDITH_TEST_RUNTIME_ROOT'])
        self.assertTrue(runtime.is_dir())
        self.assertTrue((runtime / '.owner').is_file())
        self.assertIn(str(runtime), result.stderr)
        self.assertEqual(self.defaults_calls(), [])


if __name__ == '__main__':
    unittest.main()
