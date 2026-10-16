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
    def test_timeout_retains_unbuffered_stage_marker_in_the_owned_bounded_log(self):
        class Child:
            pid = 123
            returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout):
                self.returncode = -15
                return self.returncode

        class Ownership:
            def __init__(self, leader, uid):
                self.known = {}
                self.signals = []
                owners.append(self)

            def refresh(self):
                return []

            def terminate(self, value):
                self.signals.append(value)

        marker = b'[marketplace-fixture] stage=host-build status=running pid=123\n'
        for overflow in [False, True]:
            owners = []

            def create(arguments, stdout, stderr, **options):
                self.assertEqual(stderr, marketplace.subprocess.STDOUT)
                stdout.write(marker)
                if overflow:
                    stdout.write(b'x' * 16_777_216)
                stdout.flush()
                return Child()

            with tempfile.TemporaryDirectory() as directory, patch.object(
                    marketplace.watchdog, 'owned_crash_reports', return_value=[]):
                result = marketplace.watchdog.run_batch(
                    'marketplace', ['synthetic'], Path(directory), 900 if overflow else 0,
                    process_factory=create, ownership_factory=Ownership,
                    sleep=lambda _: None, testing_process=marketplace.is_testing_process)
                log = (Path(directory) / 'marketplace.log').read_bytes()
                self.assertTrue(log.startswith(marker))
                self.assertLessEqual(len(log), 16_777_216)
            self.assertTrue(result['timedOut'])
            self.assertEqual(result['exitCode'], -15)
            self.assertFalse(marketplace.passed(result))
            self.assertEqual(owners[0].signals, [marketplace.watchdog.signal.SIGTERM])

    def test_batch_exception_retains_failure_receipt_without_claiming_execution_or_exit(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                with patch.object(sys, 'argv', ['marketplace.py']), patch.object(
                        marketplace.subprocess, 'check_output', side_effect=[
                            'a' * 40, '/Applications/Xcode.app/Contents/Developer',
                            '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build']), patch.object(
                        marketplace.watchdog, 'admit'), patch.object(
                        marketplace.watchdog, 'canonical_path', side_effect=lambda path, **_: Path(path)), patch.object(
                        marketplace, 'swift_contract', return_value={'entry': 'synthetic', 'executable': 'synthetic', 'identity': {}}), patch.object(
                        marketplace.watchdog, 'run_batch', side_effect=RuntimeError('synthetic failure')):
                    with self.assertRaises(RuntimeError):
                        marketplace.main()
                receipt = json.loads(Path('local/hosted-marketplace-tests/result.json').read_text())
                self.assertEqual(receipt['sourceCommit'], 'a' * 40)
                self.assertFalse(receipt['passed'])
                self.assertNotIn('batch', receipt)
            finally:
                os.chdir(original)

    def test_selected_swift_direct_and_in_toolchain_symlink_preserve_entry_and_pin_target(self):
        for linked in [None, 'swift-package']:
            with tempfile.TemporaryDirectory() as directory:
                developer = Path(directory).resolve() / 'Xcode.app/Contents/Developer'
                binary = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
                binary.mkdir(parents=True)
                entry = binary / 'swift-build'
                target = binary / (linked or 'swift-build')
                target.write_bytes(b'synthetic executable')
                target.chmod(0o700)
                if linked:
                    entry.symlink_to(linked)
                contract = marketplace.swift_contract(developer, entry)
                self.assertEqual(contract['entry'], str(entry))
                self.assertEqual(contract['executable'], str(target))
                calls = []
                launch = marketplace.swift_process_factory(
                    developer, contract, lambda arguments, **options: calls.append((arguments, options)))
                arguments = marketplace.command(developer, entry)
                launch(arguments, stdout=None)
                self.assertEqual(calls[0][0], arguments)
                self.assertEqual(calls[0][1]['executable'], str(target))
                target.write_bytes(b'changed same-size exe')
                with self.assertRaises(ValueError):
                    launch(arguments)
                self.assertEqual(len(calls), 1)

    def test_selected_swift_rejects_escape_nonexecutable_and_wrong_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            developer = Path(directory).resolve() / 'Xcode.app/Contents/Developer'
            binary = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
            binary.mkdir(parents=True)
            entry = binary / 'swift-build'
            outside = Path(directory).resolve() / 'foreign-swift'
            outside.write_bytes(b'synthetic executable')
            outside.chmod(0o700)
            entry.symlink_to(outside)
            with self.assertRaises(ValueError):
                marketplace.swift_contract(developer, entry)
            entry.unlink()
            entry.write_bytes(b'synthetic executable')
            entry.chmod(0o600)
            with self.assertRaises(ValueError):
                marketplace.swift_contract(developer, entry)
            entry.chmod(0o700)
            with self.assertRaises(ValueError):
                marketplace.swift_contract(developer, outside)
            with self.assertRaises(ValueError):
                marketplace.swift_contract(developer, binary / '..' / 'bin/swift')

    def test_separate_build_and_unfiltered_serial_helper_preserve_the_full_native_suite(self):
        developer = '/Applications/Xcode_26.6.app/Contents/Developer'
        self.assertEqual(marketplace.command(developer), [
            developer + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build',
            '--package-path', 'Packages/ExtensionMarketplace', '--build-system', 'native',
            '--jobs', '1', '--build-tests'])
        executable = '/owned/ExtensionMarketplacePackageTests.xctest/Contents/MacOS/ExtensionMarketplacePackageTests'
        args = marketplace.test_command('/selected/swiftpm-testing-helper', executable)
        self.assertEqual(args, ['/selected/swiftpm-testing-helper', '--test-bundle-path',
                               executable, 'test', '--skip-build', '--no-parallel',
                               '--package-path', 'Packages/ExtensionMarketplace', '--build-system',
                               'native', '--jobs', '1', executable, '--testing-library', 'swift-testing'])
        self.assertNotIn('--filter', args)
        self.assertNotIn('--skip', args)
        for unsafe in ['relative', '/foreign/Other.xctest/Contents/MacOS/Other',
                       '/owned/../ExtensionMarketplacePackageTests.xctest/Contents/MacOS/ExtensionMarketplacePackageTests']:
            with self.assertRaises(ValueError):
                marketplace.test_command('/selected/swiftpm-testing-helper', unsafe)

    def test_selected_helper_keeps_its_pinned_executable_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory).resolve() / 'swiftpm-testing-helper'
            helper.write_bytes(b'synthetic executable')
            helper.chmod(0o700)
            image = helper.parent / 'ExtensionMarketplacePackageTests.xctest/Contents/MacOS/ExtensionMarketplacePackageTests'
            image.parent.mkdir(parents=True)
            image.write_bytes(b'synthetic executable'); image.chmod(0o700)
            calls = []
            launch = marketplace.helper_process_factory(helper, image, lambda args, **options: calls.append(args))
            args = marketplace.test_command(helper, image)
            launch(args)
            self.assertEqual(calls, [args])
            with self.assertRaises(ValueError):
                launch(['/foreign/helper'])
            helper.write_bytes(b'changed synthetic exe')
            with self.assertRaises(ValueError):
                launch(args)
            self.assertEqual(len(calls), 1)
            launch = marketplace.helper_process_factory(helper, image, lambda args, **options: calls.append(args))
            image.write_bytes(b'changed synthetic exe')
            with self.assertRaises(ValueError):
                launch(args)
            self.assertEqual(len(calls), 1)

    def test_marketplace_runtime_rejects_foreign_bundles_symlinks_and_unsafe_helper(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            developer = root / 'Xcode.app/Contents/Developer'
            toolchain = developer / 'Toolchains/XcodeDefault.xctoolchain'
            helper = toolchain / 'usr/libexec/swift/pm/swiftpm-testing-helper'
            binary = root / 'Packages/ExtensionMarketplace/.build/arm64-apple-macosx/debug'
            image = binary / 'ExtensionMarketplacePackageTests.xctest/Contents/MacOS/ExtensionMarketplacePackageTests'
            platform = developer / 'Platforms/MacOSX.platform/Developer'
            testing = toolchain / 'usr/lib/swift/macosx/testing'
            for path in [helper.parent, image.parent, platform / 'Library/Frameworks',
                         platform / 'Library/PrivateFrameworks', platform / 'usr/lib', testing]:
                path.mkdir(parents=True)
            for path in [helper, image]:
                path.write_bytes(b'synthetic unexecuted'); path.chmod(0o700)
            try:
                os.chdir(root)
                selected, executable, env = marketplace.runtime_contract(developer, binary, {
                    'DYLD_LIBRARY_PATH': '/foreign/library', 'DYLD_FRAMEWORK_PATH': '/foreign/framework'})
                self.assertEqual((selected, executable), (helper, image))
                self.assertEqual(env['DYLD_LIBRARY_PATH'], str(testing) + ':' + str(platform / 'usr/lib'))
                self.assertEqual(env['NO_COLOR'], '1')
                self.assertNotIn('/foreign', env['DYLD_FRAMEWORK_PATH'])
                self.assertEqual(env['DEVELOPER_DIR'], str(developer))
                outside = root / 'foreign/debug'; outside.mkdir(parents=True)
                with self.assertRaises(ValueError):
                    marketplace.runtime_contract(developer, outside, {})
                image.unlink(); image.symlink_to(helper)
                with self.assertRaises(ValueError):
                    marketplace.runtime_contract(developer, binary, {})
                image.unlink(); image.write_bytes(b'synthetic unexecuted'); image.chmod(0o700)
                helper.chmod(0o777)
                with self.assertRaises(ValueError):
                    marketplace.runtime_contract(developer, binary, {})
            finally:
                os.chdir(original)

    def test_unreaped_child_retains_a_failure_ledger_without_claiming_zero_owned_processes(self):
        class Child:
            pid = 123
            returncode = None
            def poll(self): return None
            def wait(self, timeout): raise marketplace.subprocess.TimeoutExpired(['synthetic'], timeout)
        class Ownership:
            def __init__(self, leader, uid):
                self.known = {123: (123, 1, 2, '/owned/swiftpm-testing-helper', 123)}
            def refresh(self): return list(self.known.values())
            def identity(self, pid): return self.known.get(pid)
            def terminate(self, value): signals.append(value)
        signals = []
        with tempfile.TemporaryDirectory() as directory, patch.object(
                marketplace.watchdog, 'owned_crash_reports', return_value=[]), patch.object(
                marketplace.watchdog.subprocess, 'run'):
            result = marketplace.watchdog.run_batch(
                'marketplace', ['synthetic'], Path(directory), 0,
                process_factory=lambda *_, **__: Child(), ownership_factory=Ownership, sleep=lambda _: None,
                testing_process=marketplace.is_testing_process)
        self.assertTrue(result['retirementFailed'])
        self.assertTrue(result['observedTestingProcess'])
        self.assertEqual(result['remainingOwnedProcesses'], 1)
        self.assertFalse(marketplace.passed(result))
        self.assertIn(marketplace.watchdog.signal.SIGKILL, signals)

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
