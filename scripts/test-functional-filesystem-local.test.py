import importlib.util
import os
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('filesystem_local', Path(__file__).with_name('test-functional-filesystem-local.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FilesystemLocalTests(unittest.TestCase):
    def test_xctest_image_requires_root_ownership_single_link_and_immutable_executable(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary).resolve()
            image = root / 'synthetic-xctest'
            image.write_bytes(b'synthetic unexecuted test runner')
            image.chmod(0o755)
            def root_owned(path):
                value = path.lstat()
                names = ['st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size',
                         'st_mtime_ns', 'st_ctime_ns']
                fields = {name: getattr(value, name) for name in names}
                fields['st_uid'] = 0
                return SimpleNamespace(**fields)
            self.assertEqual(fixture.image_identity(image, root_owned)[3], 0)
            with self.assertRaises(ValueError):
                fixture.image_identity(image)
            for mode in [0o777, 0o644]:
                image.chmod(mode)
                with self.assertRaises(ValueError):
                    fixture.image_identity(image, root_owned)
            image.chmod(0o755)
            os.link(image, root / 'hardlink')
            with self.assertRaises(ValueError):
                fixture.image_identity(image, root_owned)
            (root / 'hardlink').unlink()
            alias = root / 'alias'
            alias.symlink_to(image)
            with self.assertRaises(ValueError):
                fixture.image_identity(alias, root_owned)

    def test_only_six_actual_case_passes_qualify(self):
        methods = re.findall(r'\bfunc (test\w+)\(', (fixture.ROOT / fixture.SOURCE).read_text())
        self.assertEqual(len(methods), 6)
        text = '\n'.join([
            *(f"Test Case '-[FunctionalProducerModelTests.FunctionalProducerFilesystemTests {name}]' passed (0.001 seconds)." for name in methods),
            "Test Suite 'FunctionalProducerFilesystemTests' passed at 2026-01-01 00:00:00.",
            'Executed 6 tests, with 0 failures (0 unexpected) in 0.006 seconds',
        ])
        self.assertTrue(fixture.completion(text, methods))
        for changed in ['', text.replace('6 tests', '0 tests'), text.replace('0 failures', '1 failures'),
                        text.replace(methods[0], 'testForeign'), text + '\nIssue recorded',
                        text + '\n' + text.splitlines()[0], text.replace('FunctionalProducerModelTests.', 'ForeignTests.'),
                        text + "\nTest Case '-[ForeignTests testForeign]' passed (0.001 seconds)."]:
            self.assertFalse(fixture.completion(changed, methods))

    def test_command_uses_exact_scope_private_caches_and_one_compiler(self):
        class Driver:
            developer = Path('/synthetic/developer')

            def validate(self):
                return Path('/synthetic/swift-test')
        root = Path('/synthetic/fixture')
        command = fixture.arguments(Driver(), root, root / 'build')
        self.assertEqual(command[0], '/synthetic/swift-test')
        self.assertEqual(command[1], '--package-path')
        self.assertEqual(command[-2:], ['--filter', fixture.SUITE])
        self.assertEqual(command[command.index('--jobs') + 1], '1')
        self.assertIn('--no-parallel', command)
        self.assertNotIn('--skip-build', command)
        for name in ['build', 'cache', 'config', 'security']:
            self.assertIn(str(root / name), command)

    def test_only_authenticated_xctest_image_counts_and_parent_environment_restores(self):
        original = dict(os.environ)
        image = Path('/synthetic/selected/xctest')
        child_environment = {'HOME': '/synthetic/private'}
        def run(command, root, environment, output, **options):
            self.assertEqual(dict(os.environ), child_environment)
            self.assertTrue(options['testing_process'](str(image)))
            for foreign in ['/synthetic/foreign/xctest', '/synthetic/selected/swift', 'xctest']:
                self.assertFalse(options['testing_process'](foreign))
            raise OSError('synthetic failure')
        with patch.object(fixture.native, 'run_original', side_effect=run):
            with self.assertRaises(OSError):
                fixture.execute(['synthetic'], child_environment, Path('/synthetic/output'), image)
        self.assertEqual(dict(os.environ), original)


if __name__ == '__main__':
    unittest.main()
