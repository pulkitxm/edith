import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('local_navigation', Path(__file__).with_name('test-host-navigation-local.py'))
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)


class NavigationCleanupTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        source = root / 'source.swift'
        source.write_text('@Test func synthetic() {}\n')
        return root

    def assert_retired_before_removal(self, error, *, finished=False, kill_error=None):
        root = self.fixture()
        events = []
        child = Mock(pid=123456, returncode=0)
        child.poll.return_value = 0 if finished else None
        def communicate(*, timeout=None):
            events.append('communicate' if timeout is not None else 'joined')
            if timeout is not None:
                self.assertEqual(timeout, 360)
                raise error
            return b'', None
        child.communicate.side_effect = communicate
        def kill(pid, sent):
            self.assertEqual(pid, child.pid)
            self.assertEqual(sent, navigation.signal.SIGKILL)
            events.append('kill')
            if kill_error is not None:
                raise kill_error
        remove = shutil.rmtree
        def cleanup(path):
            events.append('removed')
            remove(path)
        with patch.object(navigation, 'ROOT', root), patch.object(navigation, 'SOURCES', {'source.swift': 'Tests/HostNavigationTests/Synthetic.swift'}), patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(root)}), patch.object(navigation.sys, 'platform', 'darwin'), patch.object(navigation.subprocess, 'Popen', return_value=child) as start, patch.object(navigation.os, 'killpg', side_effect=kill), patch.object(navigation.shutil, 'rmtree', side_effect=cleanup):
            with self.assertRaises(type(error)):
                navigation.run()
        self.assertTrue(start.call_args.kwargs['start_new_session'])
        self.assertEqual(events, ['communicate', 'joined', 'removed'] if finished else ['communicate', 'kill', 'joined', 'removed'])
        self.assertFalse(list((root / 'local/host-navigation-contracts').glob('fixture-*')))

    def test_interrupt_joins_owned_child_before_deleting_fixture(self):
        self.assert_retired_before_removal(KeyboardInterrupt())

    def test_capture_error_joins_owned_child_before_deleting_fixture(self):
        self.assert_retired_before_removal(OSError('Synthetic capture error'))

    def test_exited_child_is_joined_without_signaling(self):
        self.assert_retired_before_removal(OSError('Synthetic capture error'), finished=True)

    def test_already_exited_group_still_joins_before_deleting_fixture(self):
        self.assert_retired_before_removal(KeyboardInterrupt(), kill_error=ProcessLookupError())

    def test_join_failure_keeps_private_fixture_for_the_remaining_owner(self):
        root = self.fixture()
        child = Mock(pid=123456, returncode=None)
        child.poll.return_value = None
        child.communicate.side_effect = OSError('Synthetic join error')
        with patch.object(navigation, 'ROOT', root), patch.object(navigation, 'SOURCES', {'source.swift': 'Tests/HostNavigationTests/Synthetic.swift'}), patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(root)}), patch.object(navigation.sys, 'platform', 'darwin'), patch.object(navigation.subprocess, 'Popen', return_value=child), patch.object(navigation.os, 'killpg') as kill, patch.object(navigation.shutil, 'rmtree') as remove:
            with self.assertRaisesRegex(OSError, 'Synthetic join error'):
                navigation.run()
            kill.assert_called_once_with(child.pid, navigation.signal.SIGKILL)
            remove.assert_not_called()
        self.assertEqual(len(list((root / 'local/host-navigation-contracts').glob('fixture-*'))), 1)

    def test_timeout_keeps_the_deadline_and_cannot_report_success(self):
        root = self.fixture()
        events = []
        child = Mock(pid=123456, returncode=-9)
        child.poll.return_value = -9
        def communicate(*, timeout=None):
            events.append('capture' if timeout is not None else 'joined')
            if timeout is not None:
                self.assertEqual(timeout, 360)
                raise subprocess.TimeoutExpired('Synthetic owned Swift', timeout)
            return b'', None
        child.communicate.side_effect = communicate
        def kill(pid, sent):
            self.assertEqual(pid, child.pid)
            self.assertEqual(sent, navigation.signal.SIGKILL)
            events.append('kill')
        remove = shutil.rmtree
        def cleanup(path):
            events.append('removed')
            remove(path)
        with patch.object(navigation, 'ROOT', root), patch.object(navigation, 'SOURCES', {'source.swift': 'Tests/HostNavigationTests/Synthetic.swift'}), patch.dict(os.environ, {'EDITH_LOCAL_CI_ROOT': str(root)}), patch.object(navigation.sys, 'platform', 'darwin'), patch.object(navigation.subprocess, 'Popen', return_value=child), patch.object(navigation.os, 'killpg', side_effect=kill), patch.object(navigation.shutil, 'rmtree', side_effect=cleanup), patch.object(navigation.sys, 'stdout', Mock()):
            result = navigation.run()
        self.assertEqual(result, 1)
        self.assertEqual(events, ['capture', 'kill', 'joined', 'joined', 'removed'])
        self.assertFalse(list((root / 'local/host-navigation-contracts').glob('fixture-*')))


if __name__ == '__main__':
    unittest.main()
