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


def arguments(driver, fixture, build):
    return [
        str(driver.validate()), '--package-path', str(ROOT / 'Tests/HostedFunctionalActions'),
        '--scratch-path', str(build), '--build-system', 'native', '--no-parallel', '--jobs', '1',
        '-Xswiftc', '-j1', '-Xswiftc', '-plugin-path', '-Xswiftc',
        str(driver.developer / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins'),
        '--cache-path', str(fixture / 'cache'), '--config-path', str(fixture / 'config'),
        '--security-path', str(fixture / 'security'), '--filter', SUITE,
    ]


def completion(text, methods):
    rows = re.findall(
        r"^Test Case '-\[FunctionalProducerModelTests\.FunctionalProducerFilesystemTests (\w+)\]' passed \(",
        text, re.MULTILINE)
    selected = re.findall(r"^Test Suite 'FunctionalProducerFilesystemTests' passed at ", text, re.MULTILINE)
    all_cases = re.findall(r"^Test Case '.*' passed \(", text, re.MULTILINE)
    return (sorted(rows) == sorted(methods) and len(selected) == 1 and len(all_cases) == 6
            and re.search(r'^\s*Executed 6 tests, with 0 failures \(0 unexpected\)', text, re.MULTILINE) is not None
            and re.search(r'\b(?:failed|unexpected failure|Issue recorded)\b', text, re.IGNORECASE) is None)


def execute(command, environment, output, image):
    previous = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(environment)
        return native.run_original(
            command, ROOT, environment, output, testing_process=lambda path: path == str(image))
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
        paths = [SOURCE, 'Tests/HostedFunctionalActions/Package.swift']
        for name in ['Tests/HostedFunctionalActions/ProducerSources', 'Tests/HostedFunctionalActions/Sources',
                     'Extensions/fixtureSupport', 'Packages/ExtensionMarketplace']:
            paths += [str(path.relative_to(ROOT)) for path in (ROOT / name).rglob('*.swift')
                      if '.build' not in path.relative_to(ROOT).parts]
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
            driver = driver_api.SelectedSwiftDriver(os.environ['DEVELOPER_DIR'], entry='swift-test')
            image = native.watchdog.canonical_path(
                driver.developer / 'Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest')
            metadata = image_identity(image)
            environment = isolation.environment(fixture, modules)
            for key in list(environment):
                if key.startswith('EDITH_'):
                    del environment[key]
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            environment['NO_COLOR'] = '1'
            result = execute(arguments(driver, fixture, build), environment, output, image)
            driver.validate()
            if native.watchdog.canonical_path(image) != image or image_identity(image) != metadata:
                raise ValueError('Selected XCTest image changed during execution')
            for name, digest in pins.items():
                if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                    raise ValueError('Filesystem source changed during execution')
            exact = completion((output / 'tests.log').read_text(errors='replace'), methods)
            result.update({'exactFilesystemSelection': exact, 'sourceSHA256': pins,
                           'expectedMethods': 6, 'expectedSuites': 1})
            result['passed'] = result['passed'] and exact
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
