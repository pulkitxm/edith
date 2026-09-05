import hashlib
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import install_app


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='edith-private-installer-')
        self.directory = Path(self.temporary.name).resolve()
        self.children = []
        self.native = install_app.NativeProcesses()

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        self.temporary.cleanup()

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile('/bin/sleep', path)
        path.chmod(0o755)
        return path

    def bundle(self, name, value):
        path = self.directory / name
        for relative in install_app.EXECUTABLES:
            self.executable(path / relative)
        main_info = {'CFBundleIdentifier': 'local.fixture.installer',
                     'CFBundleName': 'Private Installer Fixture',
                     'CFBundleExecutable': 'Edith', 'CFBundlePackageType': 'APPL'}
        helper_info = dict(main_info, CFBundleIdentifier='local.fixture.installer.helper')
        for base, info in ((path, main_info),
                           (path / 'Contents/Library/LoginItems/Edith.app', helper_info)):
            (base / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (path / 'Contents/Resources').mkdir()
        (path / 'Contents/Resources/version').write_text(value)
        for target in (path / 'Contents/MacOS/edithd',
                       path / 'Contents/Library/LoginItems/Edith.app', path):
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)],
                           check=True, capture_output=True, timeout=10)
        return path

    def spawn(self, executable, ignore_term=False):
        prepare = (lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN)) if ignore_term else None
        child = subprocess.Popen([str(executable), '60'], stdin=subprocess.DEVNULL,
                                 preexec_fn=prepare,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        for _ in range(100):
            identity = self.native.identity(child.pid)
            if identity and identity.path == executable.resolve():
                threading.Thread(target=child.wait, daemon=True).start()
                return child, identity
            time.sleep(0.01)
        self.fail('Private native executable did not start.')

    def digest(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_exact_executable_stops_only_owned_pid_and_waits(self):
        target = self.executable(self.directory / 'Edith.app/Contents/MacOS/edithd')
        similarly_named = self.executable(self.directory / 'EdithXapp/Contents/MacOS/edithd')
        for executable in (target, similarly_named):
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)],
                           check=True, capture_output=True, timeout=10)
        target_child, _ = self.spawn(target)
        other_child, _ = self.spawn(similarly_named)
        matches = self.native.matching({target: install_app.file_identity(target)})
        self.assertEqual([item.pid for item in matches], [target_child.pid])
        self.native.stop(matches)
        self.assertEqual(target_child.wait(timeout=1), -15)
        self.assertIsNone(other_child.poll())

    def test_forced_shutdown_waits_for_owned_process_exit(self):
        installed = self.bundle('Edith.app', 'old')
        child, identity = self.spawn(installed / install_app.EXECUTABLES[2], ignore_term=True)
        self.native.stop([identity], timeout=0.1)
        self.assertEqual(child.wait(timeout=1), -9)
        self.assertFalse(self.native.alive(identity))

    def test_mismatched_start_time_cannot_signal_live_pid(self):
        installed = self.bundle('Edith.app', 'old')
        child, identity = self.spawn(installed / install_app.EXECUTABLES[2])
        stale = install_app.dataclasses.replace(identity, started=(0, 0))
        self.native.stop([stale], timeout=0.1)
        self.assertIsNone(child.poll())

    def test_swap_retires_old_daemon_and_preserves_new_same_path_process(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        old_child, old_identity = self.spawn(installed / install_app.EXECUTABLES[2])
        source_hash = self.digest(source / install_app.EXECUTABLES[2])
        real_exchange = install_app.exchange
        new_children = []
        retired = []

        def exchange_and_start_new(staged, destination, replacing):
            real_exchange(staged, destination, replacing)
            self.assertEqual((destination / 'Contents/Resources/version').read_text(), 'new')
            self.assertEqual((staged / 'Contents/Resources/version').read_text(), 'old')
            self.assertEqual(self.native.identity(old_child.pid), old_identity)
            retired.append(staged)
            child, _ = self.spawn(destination / install_app.EXECUTABLES[2])
            new_children.append(child)

        with patch.object(install_app, 'exchange', side_effect=exchange_and_start_new):
            install_app.install(source, installed)
        self.assertEqual(old_child.wait(timeout=1), -15)
        self.assertIsNone(new_children[0].poll())
        self.assertFalse(retired[0].exists())
        self.assertEqual(self.digest(source / install_app.EXECUTABLES[2]), source_hash)
        install_app.verify_bundle(installed)

    def test_invalid_stage_preserves_original_app_and_running_daemon(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        (source / 'Contents/Resources/version').write_text('tampered')
        old_identity = install_app.file_identity(installed)
        child, _ = self.spawn(installed / install_app.EXECUTABLES[2])
        with self.assertRaises(subprocess.CalledProcessError):
            install_app.install(source, installed)
        self.assertEqual(install_app.file_identity(installed), old_identity)
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'old')
        self.assertIsNone(child.poll())

    def test_failed_copy_preserves_original_app_and_process(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        child, _ = self.spawn(installed / install_app.EXECUTABLES[2])
        with patch.object(install_app, 'copy_fixture_file', side_effect=OSError('copy failed')):
            with self.assertRaises(shutil.Error):
                install_app.install(source, installed)
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'old')
        self.assertIsNone(child.poll())

    def test_declined_normal_quit_keeps_original_and_does_not_force_exit(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        child, _ = self.spawn(installed / install_app.EXECUTABLES[0])
        calls = []

        def declined(destination, identities, processes):
            calls.extend(identities)
            raise RuntimeError('Unsaved changes')

        with self.assertRaisesRegex(RuntimeError, 'Unsaved changes'):
            install_app.install(source, installed, quit_application=declined)
        self.assertEqual([item.pid for item in calls], [child.pid])
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'old')
        self.assertIsNone(child.poll())

    def test_first_install_publishes_verified_bundle(self):
        source = self.bundle('Build.app', 'new')
        installed = self.directory / 'Edith.app'
        install_app.install(source, installed)
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'new')
        install_app.verify_bundle(installed)

    def test_atomic_swap_failure_preserves_original_and_running_process(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        child, _ = self.spawn(installed / install_app.EXECUTABLES[2])
        with patch.object(install_app, 'exchange', side_effect=OSError('swap unavailable')):
            with self.assertRaisesRegex(OSError, 'swap unavailable'):
                install_app.install(source, installed)
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'old')
        self.assertIsNone(child.poll())

    def test_cleanup_failure_keeps_retired_bundle_for_recovery(self):
        installed = self.bundle('Edith.app', 'old')
        source = self.bundle('Build.app', 'new')
        with patch.object(install_app.NativeProcesses, 'stop', side_effect=RuntimeError('drain failed')):
            with self.assertRaisesRegex(RuntimeError, 'drain failed'):
                install_app.install(source, installed)
        retired = list(self.directory.glob('.Edith.app.install-*/Edith.app'))
        self.assertEqual(len(retired), 1)
        self.assertEqual((retired[0] / 'Contents/Resources/version').read_text(), 'old')
        self.assertEqual((installed / 'Contents/Resources/version').read_text(), 'new')


if __name__ == '__main__':
    unittest.main(verbosity=2)
