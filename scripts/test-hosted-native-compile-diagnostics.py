from pathlib import Path
import importlib.util
import json
import os
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'compile_diagnostics', Path(__file__).with_name('hosted-native-compile-diagnostics.py'))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class NativeCompileDiagnosticsTests(unittest.TestCase):
    def environment(self):
        return {
            'EXPECTED_SOURCE_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40,
            'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
            'RUNNER_ENVIRONMENT': 'github-hosted',
            'GITHUB_EVENT_NAME': 'workflow_dispatch',
            'GITHUB_REPOSITORY': 'pulkitxm/edith', 'GITHUB_ACTOR_ID': '65671483',
            'GITHUB_REPOSITORY_ID': '1289153439',
            'GITHUB_REF': 'refs/heads/feat/extension-marketplace',
        }

    def test_admission_accepts_both_owners_only_at_exact_allowed_sources(self):
        for actor in ('65671483', '320458784'):
            for ref in ('refs/heads/feat/extension-marketplace', 'refs/heads/main'):
                with self.subTest(actor=actor, ref=ref):
                    environment = dict(self.environment(), GITHUB_ACTOR_ID=actor, GITHUB_REF=ref)
                    diagnostic.admit(environment, 'a' * 40)

    def test_admission_rejects_local_untrusted_event_ref_actor_and_mismatched_source(self):
        invalid = {
            'GITHUB_ACTIONS': 'false', 'RUNNER_OS': 'Linux',
            'RUNNER_ENVIRONMENT': 'self-hosted',
            'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REPOSITORY': 'other/edith',
            'GITHUB_REPOSITORY_ID': 'other',
            'GITHUB_ACTOR_ID': '999', 'GITHUB_REF': 'refs/pull/1014/merge',
            'EXPECTED_SOURCE_SHA': 'invalid', 'GITHUB_SHA': 'b' * 40,
        }
        for key, value in invalid.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.admit(dict(self.environment(), **{key: value}), 'a' * 40)
        with self.assertRaises(ValueError):
            diagnostic.admit(self.environment(), 'b' * 40)

    def test_compile_uses_original_tests_without_executing_them(self):
        command = diagnostic.compile_command('/fixture/Xcode/Developer')
        self.assertEqual(command[:2], ['swift', 'build'])
        self.assertIn('--build-tests', command)
        self.assertIn('-v', command)
        self.assertEqual(command[command.index('--package-path') + 1], 'Extensions/attention/NativeRuntime')
        self.assertEqual(command[command.index('--jobs') + 1], '1')
        self.assertNotIn('test', command)
        self.assertNotIn('--filter', command)
        self.assertNotIn('--skip', command)

    def test_compile_failure_propagates_and_preserves_driver_log(self):
        with tempfile.TemporaryDirectory() as fixture:
            destination = Path(fixture) / 'output.log'
            with patch.object(diagnostic.subprocess, 'Popen') as launch:
                def create(*args, **kwargs):
                    kwargs['stdout'].write(b'error: compile command failed with signal 4\n')
                    return launch.return_value
                launch.side_effect = create
                launch.return_value.wait.return_value = 1
                receipt = diagnostic.run_command(['swift', 'build'], fixture, {}, destination, 20)
                self.assertEqual(receipt['exit'], 1)
                self.assertFalse(receipt['timedOut'])
                self.assertIn('signal 4', destination.read_text())
                self.assertEqual(len(receipt['logSHA256']), 64)
                self.assertTrue(launch.call_args.kwargs['start_new_session'])

    def test_timeout_terminates_and_reaps_compiler_group_preserving_failure(self):
        with tempfile.TemporaryDirectory() as fixture:
            with patch.object(diagnostic.subprocess, 'Popen') as launch, patch.object(diagnostic.os, 'killpg') as kill:
                process = launch.return_value
                process.pid = 123
                process.wait.side_effect = [subprocess.TimeoutExpired('swift', 20), subprocess.TimeoutExpired('swift', 5), -9]
                receipt = diagnostic.run_command(['swift', 'build'], fixture, {}, Path(fixture) / 'out.log', 20)
                self.assertEqual(receipt['exit'], 124)
                self.assertTrue(receipt['timedOut'])
                self.assertEqual(kill.call_args_list[0].args, (123, signal.SIGTERM))
                self.assertEqual(kill.call_args_list[1].args, (123, signal.SIGKILL))
                self.assertEqual(process.wait.call_count, 3)

    def test_timeout_kills_descendants_even_if_parent_exits_during_grace(self):
        with tempfile.TemporaryDirectory() as fixture:
            with patch.object(diagnostic.subprocess, 'Popen') as launch, patch.object(diagnostic.os, 'killpg') as kill:
                process = launch.return_value
                process.pid = 123
                process.wait.side_effect = [subprocess.TimeoutExpired('swift', 20), 0, 0]
                receipt = diagnostic.run_command(['swift', 'build'], fixture, {}, Path(fixture) / 'out.log', 20)
                self.assertEqual(receipt['exit'], 124)
                self.assertEqual(kill.call_args_list[-1].args, (123, signal.SIGKILL))
                self.assertEqual(process.wait.call_count, 3)

    def test_reports_exclude_old_unrelated_symlink_and_oversized_diagnostics(self):
        with tempfile.TemporaryDirectory() as fixture:
            directory = Path(fixture) / 'reports'
            output = Path(fixture) / 'retained'
            directory.mkdir()
            output.mkdir()
            for name, process, modified in (
                ('old.ips', 'swift-frontend', 5), ('new.ips', 'swift-frontend', 15),
                ('other.ips', 'Edith', 15), ('late.ips', 'swift-frontend', 25),
            ):
                path = directory / name
                path.write_text(json.dumps({'app_name': process}) + '\n{}\n')
                os.utime(path, (modified, modified))
            (directory / 'alias.ips').symlink_to(directory / 'new.ips')
            large = directory / 'large.ips'
            with large.open('wb') as handle:
                handle.truncate(8_000_001)
            os.utime(large, (15, 15))
            retained = diagnostic.retain_compiler_reports(directory, output, 10, 20)
            self.assertEqual(len(retained), 1)
            self.assertEqual(retained[0]['processName'], 'swift-frontend')
            self.assertEqual((output / retained[0]['file']).read_bytes(), (directory / 'new.ips').read_bytes())

    def test_report_capture_is_bounded_and_accepts_text_compiler_crashes(self):
        with tempfile.TemporaryDirectory() as fixture:
            directory = Path(fixture) / 'reports'
            output = Path(fixture) / 'retained'
            directory.mkdir()
            output.mkdir()
            for index in range(7):
                path = directory / f'{index}.crash'
                path.write_text('Process: swift-frontend [123]\ncompile failure\n')
                os.utime(path, (15, 15))
            self.assertEqual(len(diagnostic.retain_compiler_reports(directory, output, 10, 20)), 4)


if __name__ == '__main__':
    unittest.main()
