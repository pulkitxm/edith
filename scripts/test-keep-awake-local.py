import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('keep_local_isolation', ROOT / 'scripts/test-account-sdk-local.py')
isolation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(isolation)
drivers = isolation.DRIVERS
HOSTED_METHOD = 'originalCheckboxOwnsAndReleasesRealSleepAssertion'
METHOD_COUNT = 47
EXECUTED_COUNT = 46


def source_inventory(root):
    digests = {}
    git_environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'GIT_OPTIONAL_LOCKS': '0',
                       'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                       'GIT_TERMINAL_PROMPT': '0'}
    tracked = set(subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z'],
                                         env=git_environment, timeout=30).decode().split('\0'))
    for prefix in ['Extensions/keepAwake', 'Extensions/fixtureSupport', 'Packages/ExtensionSupport']:
        for directory, children, names in os.walk(root / prefix, followlinks=False):
            children[:] = sorted(name for name in children if name not in {'.build', '.swiftpm', 'vendor'})
            if any((Path(directory) / name).is_symlink() for name in children):
                raise ValueError('Keep Awake source directories must not be symlinks')
            for name in sorted(names):
                path = Path(directory) / name
                if path.suffix != '.swift' and name != 'Package.resolved':
                    continue
                if name == 'Package.resolved' and str(path.relative_to(root)) not in tracked:
                    continue
                isolation.verify_source(path, root)
                digests[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for relative in ['scripts/test-keep-awake-local.py', 'scripts/test-account-sdk-local.py',
                     'scripts/run-host-swift-testing.py', 'scripts/hosted-native-owner-tests.py',
                     'scripts/hosted-host-tests/watchdog.py']:
        path = root / relative
        isolation.verify_source(path, root)
        digests[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digests


def test_methods(root):
    methods = []
    for path in sorted((root / 'Extensions/keepAwake/Tests').glob('*.swift')):
        methods.extend(re.findall(rb'@Test\b[\s\S]*?\bfunc\s+(\w+)\s*\(', path.read_bytes()))
    if len(methods) != METHOD_COUNT or len(set(methods)) != METHOD_COUNT:
        raise ValueError('Keep Awake original test inventory changed')
    if HOSTED_METHOD.encode() not in methods:
        raise ValueError('Keep Awake hosted control test is missing')
    return {value.decode() for value in methods}


def result(output, methods):
    passed = set(value.decode() for value in re.findall(rb'\bTest (\w+)\([^\r\n]*\) passed', output))
    skipped = set(value.decode() for value in re.findall(rb'\bTest (\w+)\([^\r\n]*\) skipped', output))
    summaries = re.findall(rb'Test run with (\d+) tests[^\r\n]*passed', output)
    return {'executedMethods': len(passed), 'skippedMethods': sorted(skipped),
            'passed': passed == methods - {HOSTED_METHOD} and skipped == {HOSTED_METHOD}
            and len(summaries) == 1 and int(summaries[0]) in {EXECUTED_COUNT, METHOD_COUNT}}


def environment(fixture, modules):
    values = isolation.environment(fixture, modules)
    for name in ['data', 'state', 'runtime']:
        isolation.private_directory(fixture / name)
    values.update(EDITH_EXTENSION_DATA_ROOT=str(fixture / 'data'),
                  EDITH_EXTENSION_STATE_ROOT=str(fixture / 'state'),
                  XDG_DATA_HOME=str(fixture / 'data'), XDG_STATE_HOME=str(fixture / 'state'),
                  XDG_RUNTIME_DIR=str(fixture / 'runtime'),
                  EDITH_APPLICATION_IDENTIFIER='com.pulkit.edith.dev.keep-awake-contracts',
                  EDITH_EXTENSION_ID='keepAwake',
                  EDITH_SHARED_DEFAULTS_SUITE='edith.keepAwake.local.' + fixture.name,
                  EDITH_TEST_NATIVE_CAPTURE='0', EXTENSION_SWIFT_JOBS='1', NO_COLOR='1')
    return values


def command(driver, fixture, storage):
    return drivers.SelectedPackageArguments(driver, [str(driver.validate()), '--package-path', str(ROOT / 'Extensions/keepAwake'),
            '--scratch-path', str(storage / 'build'), '--cache-path', str(fixture / 'cache'),
            '--config-path', str(fixture / 'config'), '--security-path', str(fixture / 'security'),
            '--build-system', 'native', '--no-parallel', '--jobs', '1', '-Xswiftc', '-j1',
            '-Xswiftc', '-plugin-path', '-Xswiftc',
            str(Path(os.environ['DEVELOPER_DIR']) / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins')])


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected Keep Awake local arguments')
    allowed = Path(os.environ.get('EDITH_LOCAL_CI_ROOT', ''))
    if (sys.platform != 'darwin' or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or ROOT.resolve(strict=True) != ROOT
            or not ROOT.is_relative_to(allowed)):
        raise ValueError('Keep Awake local tests require a macOS checkout on the admitted volume')
    isolation.private_directory(ROOT / 'local')
    storage = isolation.private_directory(ROOT / 'local/keep-awake-contracts')
    with os.fdopen(isolation.private_file(storage / 'run.lock', os.O_RDWR), 'r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pins = source_inventory(ROOT)
        methods = test_methods(ROOT)
        driver = drivers.SelectedSwiftDriver(os.environ['DEVELOPER_DIR'], entry='swift-test')
        fixture = isolation.private_directory(Path(tempfile.mkdtemp(prefix='fixture-', dir=storage)))
        modules = isolation.private_directory(storage / 'modules')
        child_environment = environment(fixture, modules)
        started = time.monotonic()
        owned = None
        receipt = {'sourcePins': pins, 'methodCount': METHOD_COUNT,
                   'hostedControlQualified': False, 'publicReleaseQualified': False,
                   'passed': False}
        try:
            try:
                owned = isolation.run_owned(command(driver, fixture, storage), ROOT,
                                            child_environment, fixture / 'tests.log',
                                            deadline=900, cadence=0.5)
            finally:
                driver.validate()
            output = (fixture / 'tests.log').read_bytes()
            assessment = result(output, methods)
            unchanged = source_inventory(ROOT) == pins
            receipt.update(assessment, ownership=owned, sourceUnchanged=unchanged,
                           outputSHA256=hashlib.sha256(output).hexdigest(),
                           passed=assessment['passed'] and unchanged and owned['exitCode'] == 0
                           and owned['failure'] is None and not owned['timedOut']
                           and not owned['logBoundExceeded'] and isolation.verified_cleanup(owned['cleanup']))
            isolation.write_private(storage / 'last-tests.log', output)
        except BaseException as error:
            receipt.update(failure=type(error).__name__, ownership=owned)
            raise
        finally:
            receipt['elapsedSeconds'] = time.monotonic() - started
            isolation.write_private(storage / 'last-receipt.json',
                                    (json.dumps(receipt, indent=2) + '\n').encode())
            if receipt['passed']:
                shutil.rmtree(fixture)
        print(json.dumps(receipt), flush=True)
        return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
