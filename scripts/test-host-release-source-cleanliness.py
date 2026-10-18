import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from host_release_proof import pinned_sources


class HostSourceCleanlinessTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        (self.scripts / 'clean_source_probe.py').write_text('value = 42\n')
        self.source = 'a' * 40
        self.info = {'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '123'}
        self.definitions = [{'id': 'owner' + str(i)} for i in range(39)]

    def bytecode_policy(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        job = re.search(r'(?ms)^  dmg:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)', workflow)
        self.assertIsNotNone(job)
        environment = re.search(r'(?ms)^    env:\n(.*?)(?=^    [a-zA-Z0-9_-]+:\n|\Z)', job[1])
        self.assertIsNotNone(environment)
        flag = re.search(r'^      PYTHONDONTWRITEBYTECODE: "([^"]+)"$', environment[1], re.MULTILINE)
        self.assertIsNotNone(flag)
        self.assertEqual(flag[1], '1')
        return flag[1]

    def import_fixture(self, bytecode_policy):
        environment = dict(os.environ)
        for key in ['PYTHONDONTWRITEBYTECODE', 'PYTHONPYCACHEPREFIX', 'PYTHONSTARTUP', 'PYTHONHOME']:
            environment.pop(key, None)
        environment['PYTHONPATH'] = str(self.scripts)
        if bytecode_policy is not None:
            environment['PYTHONDONTWRITEBYTECODE'] = bytecode_policy
        result = subprocess.run(
            [sys.executable, '-S', '-c', 'import sys; sys.pycache_prefix = None; import clean_source_probe; print(clean_source_probe.value)'],
            cwd=self.root, env=environment, capture_output=True, text=True, timeout=5, check=True)
        self.assertEqual(result.stdout, '42\n')

    def git_state(self, arguments):
        if arguments == ['git', 'rev-parse', 'HEAD']:
            return self.source
        if arguments == ['git', 'ls-files', '--others', '--exclude-standard', '-z']:
            return ''.join(str(path.relative_to(self.root)) + '\0' for path in self.scripts.rglob('*.pyc'))
        if arguments[:3] == ['git', 'ls-files', '--others'] or arguments == ['git', 'diff', '--name-only', 'HEAD']:
            return ''
        self.fail(str(arguments))

    def tracked_input(self, arguments):
        path = arguments[-1].split(':', 1)[1]
        if path == 'Resources/Info.plist':
            return plistlib.dumps(self.info)
        if path in ['Packages/EdithHost/Sources/EdithHostCore/Resources/index.json', 'Extensions/manifest.json']:
            return json.dumps(self.definitions).encode()
        self.fail(path)

    def test_dmg_job_applies_bytecode_policy_before_every_python_import(self):
        self.assertEqual(self.bytecode_policy(), '1')

    def test_real_python_import_keeps_source_clean_with_the_dmg_job_policy(self):
        self.import_fixture(self.bytecode_policy())
        self.assertEqual(list(self.scripts.rglob('*.pyc')), [])
        with patch('host_release_proof.subprocess.check_output', side_effect=self.tracked_input):
            info, index, dirty = pinned_sources(self.source, '1.2.3', '123', self.git_state)
        self.assertEqual(info, self.info)
        self.assertEqual(json.loads(index), self.definitions)
        self.assertFalse(dirty)

    def test_unsuppressed_real_import_still_fails_the_unchanged_source_guard(self):
        self.import_fixture(None)
        self.assertTrue(list(self.scripts.rglob('*.pyc')))
        with patch('host_release_proof.subprocess.check_output') as tracked_input:
            with self.assertRaisesRegex(ValueError, 'Untracked source inputs'):
                pinned_sources(self.source, '1.2.3', '123', self.git_state)
        tracked_input.assert_not_called()


if __name__ == '__main__':
    unittest.main()
