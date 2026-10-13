import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Tests/HostedFunctionalActions/Tests/FunctionalProducerModelTests/FunctionalProducerFilesystemTests.swift'
SUITE = 'FunctionalProducerFilesystemTests'


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


isolation = module('test-account-sdk-local')
driver_api = module('run-host-swift-testing')
native = module('hosted-native-owner-tests')


def image_identity(path, inspect=lambda path: path.lstat()):
    if path.resolve(strict=True) != path:
        raise ValueError('XCTest image must be canonical')
    value = inspect(path)
    if (not stat.S_ISREG(value.st_mode) or value.st_uid != 0 or value.st_nlink != 1
            or value.st_mode & 0o022 or value.st_mode & 0o111 == 0):
        raise ValueError('XCTest image must be immutable and root owned')
    return tuple(getattr(value, name) for name in [
        'st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns',
    ])


def build_arguments(driver, fixture, build):
    return [
        str(driver.validate()), '--build-tests',
        '--package-path', str(ROOT / 'Tests/HostedFunctionalActions'),
        '--scratch-path', str(build), '--build-system', 'native', '--jobs', '1',
        '-Xswiftc', '-j1', '-Xswiftc', '-plugin-path', '-Xswiftc',
        str(driver.developer / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins'),
        '--cache-path', str(fixture / 'cache'), '--config-path', str(fixture / 'config'),
        '--security-path', str(fixture / 'security'),
    ]


def test_arguments(image, bundle, methods):
    if len(methods) != 6 or len(set(methods)) != 6 or any(re.fullmatch(r'test[A-Za-z0-9_]+', name) is None for name in methods):
        raise ValueError('Filesystem XCTest identifiers changed')
    identifiers = ['FunctionalProducerModelTests.' + SUITE + '/' + name for name in methods]
    return [str(image), '-XCTest', ','.join(identifiers), str(bundle)]


def bundle_identity(build):
    build = native.watchdog.canonical_path(build, directory=True)
    architecture = os.uname().machine
    if architecture not in {'arm64', 'x86_64'}:
        raise ValueError('Unexpected filesystem test architecture')
    bundle = native.watchdog.canonical_path(
        build / (architecture + '-apple-macosx/debug/HostedFunctionalActionsPackageTests.xctest'), directory=True)
    bundle_info = bundle.lstat()
    fields = ['st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns']
    bundle_metadata = tuple(getattr(bundle_info, name) for name in fields)
    if bundle_info.st_uid != os.getuid() or bundle_info.st_mode & 0o022:
        raise ValueError('Filesystem test bundle must be immutable and owned')
    executable = native.watchdog.canonical_path(bundle / 'Contents/MacOS/HostedFunctionalActionsPackageTests')
    descriptor = os.open(executable, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        identity = tuple(getattr(before, name) for name in fields)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_nlink != 1 or before.st_mode & 0o022 or not 0 < before.st_size <= 268435456):
            raise ValueError('Filesystem test artifact must be owned and bounded')
        remaining = before.st_size
        digest = hashlib.sha256()
        while remaining:
            block = os.read(descriptor, min(remaining, 1_048_576))
            if not block:
                raise ValueError('Filesystem test artifact truncated during qualification')
            digest.update(block)
            remaining -= len(block)
        if (os.read(descriptor, 1)
                or tuple(getattr(os.fstat(descriptor), name) for name in fields) != identity
                or tuple(getattr(executable.lstat(), name) for name in fields) != identity
                or tuple(getattr(bundle.lstat(), name) for name in fields) != bundle_metadata):
            raise ValueError('Filesystem test artifact changed during qualification')
    finally:
        os.close(descriptor)
    return bundle, executable, identity, digest.hexdigest(), bundle_metadata


def phase_success(value):
    return (type(value['exitCode']) is int and value['exitCode'] == 0
            and value['timedOut'] is False and value['logBoundExceeded'] is False
            and value['failure'] is None and isolation.verified_cleanup(value['cleanup']))


def remaining_budget(started):
    elapsed = time.monotonic() - started
    if not 0 <= elapsed < native.TEST_DEADLINE:
        raise ValueError('Filesystem native deadline expired or moved backwards')
    return native.TEST_DEADLINE - elapsed


def completion(text, methods):
    rows = re.findall(
        r"^Test Case '-\[FunctionalProducerModelTests\.FunctionalProducerFilesystemTests (\w+)\]' passed \(",
        text, re.MULTILINE)
    selected = re.findall(r"^Test Suite 'FunctionalProducerFilesystemTests' passed at ", text, re.MULTILINE)
    all_cases = re.findall(r"^Test Case '.*' passed \(", text, re.MULTILINE)
    return (sorted(rows) == sorted(methods) and len(selected) == 1 and len(all_cases) == 6
            and re.search(r'^\s*Executed 6 tests, with 0 failures \(0 unexpected\)', text, re.MULTILINE) is not None
            and re.search(r'\b(?:failed|unexpected failure|Issue recorded)\b', text, re.IGNORECASE) is None)


def execute_build(command, environment, output, deadline):
    return isolation.run_owned(command, ROOT, environment, output / 'tests.log',
                               deadline=deadline, cadence=0.5)


def execute(command, environment, output, image=None, deadline=native.TEST_DEADLINE):
    previous = dict(os.environ)
    admitted = False

    def owner(pid, uid):
        nonlocal admitted
        value = native.BoundedOwnership(pid, uid)
        identity = value.known.get(pid)
        admitted = (image is not None and identity is not None and identity[0] == pid
                    and identity[3] == str(image)
                    and identity[:3] + identity[4:5] == value.current_seal(pid))
        return value

    try:
        os.environ.clear()
        os.environ.update(environment)
        result = native.run_original(
            command, ROOT, environment, output, deadline=deadline, ownership_factory=owner,
            testing_process=lambda path: image is not None and path == str(image))
        result['constructorObservedTestingProcess'] = admitted
        result['observedTestingProcess'] = result['observedTestingProcess'] or admitted
        result['passed'] = phase_success(result) and result['testsCompleted'] and result['observedTestingProcess']
        return result
    finally:
        os.environ.clear()
        os.environ.update(previous)


def run():
    if sys.argv[1:]:
        raise ValueError('Unexpected local filesystem fixture arguments')
    allowed = Path(os.environ['EDITH_LOCAL_CI_ROOT'])
    if (sys.platform != 'darwin' or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed)):
        raise ValueError('Filesystem fixtures require a checkout inside EDITH_LOCAL_CI_ROOT')
    storage = isolation.private_directory(isolation.private_directory(ROOT / 'local') / 'filesystem-contracts')
    with os.fdopen(isolation.private_file(storage / 'run.lock', os.O_RDWR), 'r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        paths = []
        for name in ['Tests/HostedFunctionalActions',
                     'Extensions/fixtureSupport', 'Packages/ExtensionMarketplace']:
            paths += [str(path.relative_to(ROOT)) for path in (ROOT / name).rglob('*.swift')
                      if '.build' not in path.relative_to(ROOT).parts]
        paths += ['scripts/test-functional-filesystem-local.py', 'scripts/hosted-native-owner-tests.py',
                  'scripts/test-account-sdk-local.py', 'scripts/run-host-swift-testing.py',
                  'scripts/hosted-host-tests/watchdog.py']
        pins = {}
        for name in paths:
            isolation.verify_source(ROOT / name, ROOT)
            pins[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        source = (ROOT / SOURCE).read_text()
        methods = re.findall(r'\bfunc (test\w+)\(', source)
        if len(methods) != 6 or len(set(methods)) != 6:
            raise ValueError('Filesystem test selection changed')
        fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=storage))
        output = isolation.private_directory(fixture / 'output')
        modules = isolation.private_directory(storage / 'modules')
        build = isolation.private_directory(storage / 'build')
        qualified = False
        try:
            driver = driver_api.SelectedSwiftDriver(os.environ['DEVELOPER_DIR'], entry='swift-build')
            image = native.watchdog.canonical_path(
                driver.developer / 'Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest')
            metadata = image_identity(image)
            environment = isolation.environment(fixture, modules)
            for key in list(environment):
                if key.startswith('EDITH_'):
                    del environment[key]
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            environment['NO_COLOR'] = '1'
            started = time.monotonic()
            build_output = isolation.private_directory(fixture / 'build-output')
            build_result = execute_build(build_arguments(driver, fixture, build), environment, build_output,
                                         deadline=remaining_budget(started))
            isolation.write_private(storage / 'build-receipt.json', (json.dumps(build_result, indent=2) + '\n').encode())
            driver.validate()
            build_passed = phase_success(build_result)
            if not build_passed:
                build_result.update({'passed': False, 'buildPassed': False, 'testsExecuted': False})
                isolation.write_private(storage / 'last-receipt.json', (json.dumps(build_result, indent=2) + '\n').encode())
                sys.stdout.buffer.write((build_output / 'tests.log').read_bytes())
                print(json.dumps(build_result), flush=True)
                return 1
            for name, digest in pins.items():
                if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                    raise ValueError('Filesystem source changed during build')
            if native.watchdog.canonical_path(image) != image or image_identity(image) != metadata:
                raise ValueError('Selected XCTest image changed during build')
            artifact = bundle_identity(build)
            platform = driver.developer / 'Platforms/MacOSX.platform'
            environment['DYLD_FRAMEWORK_PATH'] = ':'.join(str(native.watchdog.canonical_path(
                platform / 'Developer/Library' / name, directory=True))
                for name in ['Frameworks', 'PrivateFrameworks'])
            environment['DYLD_LIBRARY_PATH'] = str(native.watchdog.canonical_path(
                platform / 'Developer/usr/lib', directory=True))
            result = execute(test_arguments(image, artifact[0], methods), environment, output, image,
                             deadline=remaining_budget(started))
            if bundle_identity(build) != artifact:
                raise ValueError('Filesystem test artifact changed during execution')
            driver.validate()
            if native.watchdog.canonical_path(image) != image or image_identity(image) != metadata:
                raise ValueError('Selected XCTest image changed during execution')
            for name, digest in pins.items():
                if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                    raise ValueError('Filesystem source changed during execution')
            exact = completion((output / 'tests.log').read_text(errors='replace'), methods)
            result.update({'exactFilesystemSelection': exact, 'sourceSHA256': pins,
                           'expectedMethods': 6, 'expectedSuites': 1})
            result.update({'buildPassed': build_passed, 'testArtifactSHA256': artifact[3]})
            result['passed'] = (build_passed and result['passed'] and exact
                                and isolation.verified_cleanup(result['cleanup']))
            isolation.write_private(storage / 'last-receipt.json', (json.dumps(result, indent=2) + '\n').encode())
            sys.stdout.buffer.write((output / 'tests.log').read_bytes())
            print(json.dumps(result), flush=True)
            qualified = result['passed']
            return 0 if qualified else 1
        finally:
            if qualified:
                shutil.rmtree(fixture)


if __name__ == '__main__':
    sys.exit(run())
